import AVFoundation
import AudioToolbox
import Foundation
import OSLog

enum AudioRecorderError: LocalizedError {
    case microphoneDenied
    case unavailableInput
    case deviceConfigurationFailed(String, OSStatus)
    case notRecording
    case noAudioCaptured(String)
    case silentInput(String, Float)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        case .unavailableInput:
            return "No usable microphone input is available."
        case let .deviceConfigurationFailed(name, status):
            return "MicMyDay could not use the selected microphone “\(name)” (macOS error \(status))."
        case .notRecording:
            return "There is no active recording to stop."
        case let .noAudioCaptured(name):
            return "The selected microphone “\(name)” delivered no audio frames. Choose another input device in Settings → Voice."
        case let .silentInput(name, peakDecibels):
            return String(
                format: "The selected microphone “%@” produced a very weak signal (peak %.0f dBFS). Check that it is connected and unmuted, or choose another input device in Settings → Voice.",
                name,
                peakDecibels
            )
        case let .writeFailed(error):
            return "The microphone recording could not be saved: \(error.localizedDescription)"
        }
    }
}

final class AudioRecorder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "AudioRecorder"
    )
    private static let minimumUsableAmplitude: Float = 0.001

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var writingError: Error?
    private var tapInstalled = false
    /// True while a microphone is deliberately kept open after capture ended.
    private(set) var holdingInput = false
    /// Guards the handover of the capture flag and the file between the audio
    /// thread, which writes buffers, and the caller that finalizes them. The
    /// tap keeps running while a wireless headset is held open, so without this
    /// a buffer can pass the capture check and then write into a file that is
    /// being closed and handed to transcription.
    /// Called once per recording, when the first buffer arrives from the
    /// device. That is the only honest signal that the microphone is genuinely
    /// listening: `start()` returning means the graph was built, which on a
    /// wireless headset happens a second or so before any audio flows.
    private var onFirstBuffer: (@MainActor () -> Void)?
    private var sawFirstBuffer = false

    /// Set before `start()`, never after: a wireless headset can deliver its
    /// first buffer while `start()` is still returning, and a handler installed
    /// afterwards would miss the only event it exists to catch.
    ///
    /// Takes the same lock as the tap, because the tap reads this on the audio
    /// thread while the caller writes it on the main actor.
    func setFirstBufferHandler(_ handler: (@MainActor () -> Void)?) {
        captureLock.lock()
        onFirstBuffer = handler
        sawFirstBuffer = false
        captureLock.unlock()
    }

    private let captureLock = NSLock()
    private var capturing = false
    private let meteringLock = NSLock()
    private var capturedFrameCount: AVAudioFramePosition = 0
    private var maximumObservedAmplitude: Float = 0
    private var lastLevelEmissionUptime: TimeInterval = 0
    private var activeDeviceName: String?
    private var activeSampleRate: Double = 0

    // Auto-stop on silence (peak-amplitude thresholds; the recorder already
    // meters every buffer, so the detector adds no measurable cost).
    private static let speechPeakThreshold: Float = 0.04
    private static let silencePeakThreshold: Float = 0.012
    private var silenceAutoStopSeconds: Double = 0
    private var speechDetected = false
    private var silenceFrames: AVAudioFramePosition = 0
    private var autoStopFired = false

    /// Called from the audio render thread with a normalized 0...1 meter value.
    var onInputLevel: ((Float) -> Void)?

    /// Every captured buffer, as it arrives, for anything that transcribes
    /// while the user is still speaking.
    ///
    /// Called on the audio thread, inside the capture lock. Whatever is on the
    /// other end must return immediately and must not touch the main actor:
    /// blocking here drops audio, and dropped audio is the recording.
    ///
    /// Stored behind the same lock the audio thread reads it under. Assigning
    /// it from the main actor while that thread is reading it is a race on the
    /// closure itself, and clearing it releases the captured object underneath
    /// a thread about to call it.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get {
            captureLock.lock()
            defer { captureLock.unlock() }
            return bufferHandler
        }
        set {
            captureLock.lock()
            bufferHandler = newValue
            captureLock.unlock()
        }
    }

    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main queue once when speech has been followed by the
    /// configured stretch of silence. Only fires if enabled via start(...).
    var onSilenceAutoStop: (() -> Void)?

    var isRecording: Bool { engine.isRunning }

    static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch microphoneAuthorizationStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    /// Brings the audio graph up to the point where only `start()` is left.
    ///
    /// Everything here happens on the first press otherwise, and it is the
    /// expensive part: resolving the device, handing it to the audio unit and
    /// asking CoreAudio for the input format all talk to the audio daemon, and
    /// a cold one is slow. Doing it while idle is why a second dictation
    /// started right after the first feels instant and the first one does not.
    ///
    /// Best effort throughout: a failure here is not an error, it only means
    /// `start()` pays the cost as before.
    func prewarm(inputDeviceUID: String?) {
        guard !engine.isRunning, Self.microphoneAuthorizationStatus == .authorized else { return }
        guard let device = try? AudioInputDeviceManager.resolveInputDevice(uid: inputDeviceUID),
              let audioUnit = engine.inputNode.audioUnit else { return }
        // Warming a wireless headset would mean holding it in its microphone
        // profile the whole time the app is idle, which costs battery and makes
        // anything the user is listening to sound worse. The delay on the first
        // press is the better trade.
        guard !device.isWireless else { return }
        var deviceID = device.deviceID
        guard AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { return }
        _ = engine.inputNode.inputFormat(forBus: 0)
        engine.prepare()
    }

    /// silenceAutoStopSeconds: 0 disables silence auto-stop; a positive value
    /// fires onSilenceAutoStop after speech is followed by that much silence.
    @discardableResult
    func start(inputDeviceUID: String?, silenceAutoStopSeconds: Double = 0) async throws -> AudioInputDevice {
        guard await Self.requestMicrophoneAccess() else {
            throw AudioRecorderError.microphoneDenied
        }
        self.silenceAutoStopSeconds = max(0, silenceAutoStopSeconds)

        if holdingInput {
            // A previous dictation is still holding a wireless headset open so
            // its closing cue could be heard. It is finished with; take the
            // microphone back rather than trying to stop a recording that has
            // already ended.
            releaseInput()
        } else if engine.isRunning {
            _ = try stop()
        }
        engine.reset()

        let selectedDevice = try AudioInputDeviceManager.resolveInputDevice(uid: inputDeviceUID)
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw AudioRecorderError.unavailableInput
        }

        var deviceID = selectedDevice.deviceID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw AudioRecorderError.deviceConfigurationFailed(selectedDevice.name, deviceStatus)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.unavailableInput
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicMyDay-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        writingError = nil
        outputURL = url
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        activeDeviceName = selectedDevice.name
        activeSampleRate = format.sampleRate
        resetMetering()

        captureLock.lock()
        capturing = true
        captureLock.unlock()
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureLock.lock()
            defer { self.captureLock.unlock() }
            guard self.capturing, self.writingError == nil else { return }
            if !self.sawFirstBuffer, let announce = self.onFirstBuffer {
                self.sawFirstBuffer = true
                self.onFirstBuffer = nil
                Task { @MainActor in announce() }
            }
            self.observe(buffer)
            // Before the file write, so live recognition is not held up by
            // disk, and outside any concern about the write failing: the file
            // is the fallback, not the only path.
            self.bufferHandler?(buffer)
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                self.writingError = error
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeInputTapIfNeeded()
            audioFile = nil
            outputURL = nil
            activeDeviceName = nil
            activeSampleRate = 0
            resetMetering()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        Self.logger.info(
            "Recording started: device=\(selectedDevice.name, privacy: .public), deviceID=\(selectedDevice.deviceID), sampleRate=\(format.sampleRate), channels=\(format.channelCount)"
        )

        return selectedDevice
    }

    /// Finishes the recording and gives back the file.
    ///
    /// `holdingInputOpen` leaves the microphone running afterwards, for a
    /// wireless headset. Releasing it makes macOS switch the headset back out
    /// of its microphone profile, and that switch destroys any cue playing at
    /// the time, so the caller keeps the input until the last cue has been
    /// heard and then calls `releaseInput()`. Capture itself stops here either
    /// way: no audio recorded after this point reaches the file.
    func stop(holdingInputOpen: Bool = false) throws -> URL {
        guard let outputURL else { throw AudioRecorderError.notRecording }

        // Taken before anything is torn down: once this returns, no buffer
        // already in flight is still writing to the file.
        captureLock.lock()
        capturing = false
        captureLock.unlock()

        holdingInput = holdingInputOpen
        if !holdingInputOpen {
            if engine.isRunning {
                engine.stop()
            }
            removeInputTapIfNeeded()
        }
        audioFile = nil
        self.outputURL = nil
        let deviceName = activeDeviceName ?? "Unknown Input"
        activeDeviceName = nil
        let sampleRate = activeSampleRate
        activeSampleRate = 0
        let meter = meteringSnapshotAndReset()
        onInputLevel?(0)

        let peakDecibels = Self.decibels(for: meter.maximumAmplitude)
        let duration = sampleRate > 0 ? Double(meter.frames) / sampleRate : 0
        Self.logger.info(
            "Recording stopped: device=\(deviceName, privacy: .public), duration=\(duration, format: .fixed(precision: 2))s, frames=\(meter.frames), peak=\(peakDecibels, format: .fixed(precision: 1))dBFS"
        )

        if let writingError {
            self.writingError = nil
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioRecorderError.writeFailed(writingError)
        }

        guard meter.frames > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioRecorderError.noAudioCaptured(deviceName)
        }
        guard meter.maximumAmplitude >= Self.minimumUsableAmplitude else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioRecorderError.silentInput(deviceName, peakDecibels)
        }

        return outputURL
    }

    /// Throws the recording away.
    ///
    /// `holdingInputOpen` keeps a wireless headset's microphone running, for
    /// the same reason `stop(holdingInputOpen:)` does: the failure cue still
    /// has to be heard, and letting the microphone go first is what destroys
    /// it. The caller releases it afterwards.
    func cancel(holdingInputOpen: Bool = false) {
        captureLock.lock()
        capturing = false
        captureLock.unlock()
        holdingInput = holdingInputOpen
        if !holdingInputOpen {
            if engine.isRunning {
                engine.stop()
            }
            removeInputTapIfNeeded()
        }
        audioFile = nil
        writingError = nil
        activeDeviceName = nil
        activeSampleRate = 0
        resetMetering()
        onInputLevel?(0)
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
    }

    /// Lets go of a microphone that `stop(holdingInputOpen:)` kept open.
    /// Safe to call when nothing is held.
    func releaseInput() {
        captureLock.lock()
        capturing = false
        captureLock.unlock()
        holdingInput = false
        if engine.isRunning {
            engine.stop()
        }
        removeInputTapIfNeeded()
    }

    private func removeInputTapIfNeeded() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func observe(_ buffer: AVAudioPCMBuffer) {
        let amplitude = Self.maximumAmplitude(in: buffer)
        let now = ProcessInfo.processInfo.systemUptime
        var shouldEmitLevel = false
        var shouldFireAutoStop = false
        meteringLock.lock()
        capturedFrameCount += AVAudioFramePosition(buffer.frameLength)
        maximumObservedAmplitude = max(maximumObservedAmplitude, amplitude)
        if now - lastLevelEmissionUptime >= 0.05 {
            lastLevelEmissionUptime = now
            shouldEmitLevel = true
        }
        if silenceAutoStopSeconds > 0, !autoStopFired, activeSampleRate > 0 {
            if amplitude >= Self.speechPeakThreshold {
                speechDetected = true
                silenceFrames = 0
            } else if amplitude < Self.silencePeakThreshold {
                silenceFrames += AVAudioFramePosition(buffer.frameLength)
            } else {
                silenceFrames = 0
            }
            if speechDetected, Double(silenceFrames) / activeSampleRate >= silenceAutoStopSeconds {
                autoStopFired = true
                shouldFireAutoStop = true
            }
        }
        meteringLock.unlock()
        if shouldEmitLevel {
            onInputLevel?(Self.normalizedMeterLevel(for: amplitude))
        }
        if shouldFireAutoStop {
            DispatchQueue.main.async { [weak self] in
                self?.onSilenceAutoStop?()
            }
        }
    }

    private func resetMetering() {
        meteringLock.lock()
        capturedFrameCount = 0
        maximumObservedAmplitude = 0
        lastLevelEmissionUptime = 0
        speechDetected = false
        silenceFrames = 0
        autoStopFired = false
        meteringLock.unlock()
    }

    private func meteringSnapshotAndReset() -> (frames: AVAudioFramePosition, maximumAmplitude: Float) {
        meteringLock.lock()
        let snapshot = (capturedFrameCount, maximumObservedAmplitude)
        capturedFrameCount = 0
        maximumObservedAmplitude = 0
        lastLevelEmissionUptime = 0
        meteringLock.unlock()
        return snapshot
    }

    private static func decibels(for amplitude: Float) -> Float {
        guard amplitude > 0 else { return -120 }
        return 20 * log10(amplitude)
    }

    private static func normalizedMeterLevel(for amplitude: Float) -> Float {
        let decibels = max(-60, decibels(for: amplitude))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private static func maximumAmplitude(in buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        let isInterleaved = buffer.format.isInterleaved
        let bufferCount = isInterleaved ? 1 : channelCount
        let samplesPerBuffer = frameCount * (isInterleaved ? channelCount : 1)
        var maximum: Float = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return 0 }
            for channel in 0 ..< bufferCount {
                for index in 0 ..< samplesPerBuffer {
                    maximum = max(maximum, abs(channelData[channel][index]))
                }
            }
        case .pcmFormatFloat64:
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else { continue }
                let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.stride
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0 ..< sampleCount {
                    maximum = max(maximum, Float(abs(samples[index])))
                }
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return 0 }
            for channel in 0 ..< bufferCount {
                for index in 0 ..< samplesPerBuffer {
                    let value = abs(Int32(channelData[channel][index]))
                    maximum = max(maximum, Float(value) / Float(Int16.max))
                }
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return 0 }
            for channel in 0 ..< bufferCount {
                for index in 0 ..< samplesPerBuffer {
                    let value = abs(Int64(channelData[channel][index]))
                    maximum = max(maximum, Float(value) / Float(Int32.max))
                }
            }
        case .otherFormat:
            // The input node normally provides linear PCM. Avoid classifying an
            // unfamiliar but valid format as silence solely because it cannot be metered.
            return 1
        @unknown default:
            return 1
        }
        return maximum
    }
}
