import AVFoundation
import AudioToolbox
import Foundation
import OSLog

/// Continuously monitors the microphone with an energy-based voice activity
/// detector. When sustained sound is detected it captures a segment (including
/// a pre-roll so the first word is not clipped), finalizes it after a stretch
/// of silence, and hands the caller a WAV file. The detector is a handful of
/// float operations per audio buffer — CPU cost is negligible.
final class VoiceActivationListener {
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "VoiceActivation")

    // Detector tuning (RMS, linear 0...1): speech onset must exceed startRMS
    // for startConfirmationSeconds; the segment ends after silenceSeconds
    // below endRMS. Segments shorter than minimumSpeechSeconds are discarded
    // as noise (door slam, cough, keyboard).
    private static let startRMS: Float = 0.018
    private static let endRMS: Float = 0.006
    private static let startConfirmationSeconds = 0.06
    private static let preRollSeconds = 0.8
    private static let minimumSpeechSeconds = 0.3

    private var silenceSeconds = 1.2

    /// All callbacks are delivered on the main queue.
    var onSpeechStart: (() -> Int)?
    /// Delivered with the token `onSpeechStart`'s handler returned for this
    /// segment, so the receiver can tell a late delivery from the segment it
    /// is currently expecting. The token is captured when the segment begins
    /// and travels with it through the background write: read from shared
    /// state at delivery time instead, a segment cancelled while its file was
    /// still being written could pass a newer segment's check.
    var onSpeechSegment: ((URL, Int) -> Void)?
    /// A started segment was dropped (too short, aborted, or unwritable).
    var onSpeechDiscarded: ((Int) -> Void)?
    var onInputLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let writeQueue = DispatchQueue(label: "com.micmyday.app.vad-write", qos: .userInitiated)
    private var tapInstalled = false
    private var maximumSegmentSeconds: Double = 120

    // Detector state, touched only from the audio tap thread except for the
    // lock-guarded control flags below.
    private var inSpeech = false
    private var speechFrames: AVAudioFramePosition = 0
    private var confirmationFrames: AVAudioFramePosition = 0
    private var silenceFrames: AVAudioFramePosition = 0
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFramePosition = 0
    private var segmentBuffers: [AVAudioPCMBuffer] = []
    private var lastLevelEmissionUptime: TimeInterval = 0

    private let controlLock = NSLock()
    private var forceEndRequested = false
    /// Wall-clock backstop for a segment. The detector only finalises inside an
    /// audio callback, so if the input device disappears mid-phrase (USB or
    /// Bluetooth microphone unplugged, engine stalled) both Stop and the
    /// duration limit stop working and the app sits in `.recording` forever.
    private var segmentWatchdog: DispatchWorkItem?
    /// The tap's format, so the watchdog can write out a segment without an
    /// audio callback to hand it one.
    private var activeFormat: AVAudioFormat?
    private var abortRequested = false

    private(set) var isListening = false

    func start(inputDeviceUID: String?, maximumSegmentSeconds: Int, silenceSeconds: Double = 1.2) throws {
        guard !isListening else { return }
        self.maximumSegmentSeconds = Double(max(5, maximumSegmentSeconds))
        self.silenceSeconds = min(10, max(0.3, silenceSeconds))

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

        resetDetectorState()
        activeFormat = format
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.process(buffer, format: format)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTapIfNeeded()
            throw error
        }
        isListening = true
        Self.logger.info("Voice activation listening on \(selectedDevice.name, privacy: .public)")
    }

    func stop() {
        guard isListening || engine.isRunning else { return }
        if engine.isRunning { engine.stop() }
        removeTapIfNeeded()
        resetDetectorState()
        isListening = false
        onInputLevel?(0)
    }

    /// Finalizes the in-flight segment (if any) on the next audio callback, or
    /// shortly afterwards if no further callback arrives.
    func endSpeechNow() {
        controlLock.lock()
        forceEndRequested = true
        controlLock.unlock()
        scheduleSegmentWatchdog(after: 1.0)
    }

    /// Drops the in-flight segment (if any) without transcribing it.
    func abortSegment() {
        controlLock.lock()
        abortRequested = true
        controlLock.unlock()
        scheduleSegmentWatchdog(after: 1.0)
    }

    /// Finalises the segment when the tap has gone quiet. The tap is removed
    /// first so the audio thread cannot be mutating detector state while this
    /// runs, which also means the listener has to be rearmed afterwards.
    private func scheduleSegmentWatchdog(after seconds: TimeInterval) {
        segmentWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.inSpeech else { return }
            Self.logger.notice("Voice segment watchdog fired; no audio callback arrived")
            self.removeTapIfNeeded()
            self.engine.stop()
            self.controlLock.lock()
            let discard = self.abortRequested
            self.abortRequested = false
            self.forceEndRequested = false
            self.controlLock.unlock()
            self.endSegment(discard: discard, format: self.activeFormat)
            self.isListening = false
            self.onInputLevel?(0)
        }
        segmentWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func resetDetectorState() {
        // The watchdog belongs to the segment being reset away. Left armed, it
        // fired into the next segment after a stop/restart and finalized a
        // recording it never owned.
        segmentWatchdog?.cancel()
        segmentWatchdog = nil
        inSpeech = false
        speechFrames = 0
        confirmationFrames = 0
        silenceFrames = 0
        preRollBuffers = []
        preRollFrames = 0
        segmentBuffers = []
        lastLevelEmissionUptime = 0
        controlLock.lock()
        forceEndRequested = false
        abortRequested = false
        controlLock.unlock()
    }

    // Runs on the audio tap thread.
    private func process(_ tapBuffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        // The engine may reuse the tap buffer instance; retained audio must be copied.
        guard let buffer = Self.copy(tapBuffer) else { return }
        let sampleRate = format.sampleRate
        let frames = AVAudioFramePosition(buffer.frameLength)
        let rms = Self.rms(of: buffer)

        emitLevelIfDue(rms: rms)

        controlLock.lock()
        let forceEnd = forceEndRequested
        let abort = abortRequested
        forceEndRequested = false
        abortRequested = false
        controlLock.unlock()

        if abort, inSpeech {
            endSegment(discard: true)
        }

        if inSpeech {
            segmentBuffers.append(buffer)
            speechFrames += frames
            if rms < Self.endRMS {
                silenceFrames += frames
            } else {
                silenceFrames = 0
            }
            let silenceElapsed = Double(silenceFrames) / sampleRate
            let totalElapsed = Double(speechFrames) / sampleRate
            if forceEnd || silenceElapsed >= silenceSeconds || totalElapsed >= maximumSegmentSeconds {
                let spokenSeconds = totalElapsed - silenceElapsed
                endSegment(discard: spokenSeconds < Self.minimumSpeechSeconds, format: format)
            }
        } else {
            appendPreRoll(buffer, frames: frames, sampleRate: sampleRate)
            if rms >= Self.startRMS {
                confirmationFrames += frames
                if Double(confirmationFrames) / sampleRate >= Self.startConfirmationSeconds {
                    beginSegment()
                }
            } else {
                confirmationFrames = 0
            }
        }
    }

    /// The token of the segment currently recording, captured from the client
    /// when it began. Written on the main queue in `beginSegment`'s callback
    /// and read when a segment ends; both under `stateQueue` ordering below.
    private var segmentToken = 0

    private func beginSegment() {
        inSpeech = true
        speechFrames = 0
        silenceFrames = 0
        confirmationFrames = 0
        segmentBuffers = preRollBuffers
        preRollBuffers = []
        preRollFrames = 0
        Self.logger.info("Speech detected, segment started")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.segmentToken = self.onSpeechStart?() ?? 0
        }
    }

    private func endSegment(discard: Bool, format: AVAudioFormat? = nil) {
        segmentWatchdog?.cancel()
        segmentWatchdog = nil
        let buffers = segmentBuffers
        segmentBuffers = []
        inSpeech = false
        speechFrames = 0
        silenceFrames = 0
        confirmationFrames = 0

        Self.logger.info("Segment ended, discard=\(discard), buffers=\(buffers.count)")
        guard !discard, let format, !buffers.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onSpeechDiscarded?(self.segmentToken)
            }
            return
        }

        // Read on the main queue, where beginSegment's callback wrote it, and
        // *before* the write begins: by the time the file is finished a newer
        // segment may have started and replaced the property.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let token = self.segmentToken
            self.write(buffers: buffers, format: format, token: token)
        }
    }

    private func write(buffers: [AVAudioPCMBuffer], format: AVAudioFormat, token: Int) {
        writeQueue.async { [weak self] in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MicMyDay-vad-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                for buffer in buffers {
                    try file.write(from: buffer)
                }
            } catch {
                Self.logger.error("Voice segment write failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self?.onSpeechDiscarded?(token)
                }
                return
            }
            DispatchQueue.main.async {
                self?.onSpeechSegment?(url, token)
            }
        }
    }

    private func appendPreRoll(_ buffer: AVAudioPCMBuffer, frames: AVAudioFramePosition, sampleRate: Double) {
        preRollBuffers.append(buffer)
        preRollFrames += frames
        let limit = AVAudioFramePosition(Self.preRollSeconds * sampleRate)
        while preRollFrames > limit, preRollBuffers.count > 1 {
            let removed = preRollBuffers.removeFirst()
            preRollFrames -= AVAudioFramePosition(removed.frameLength)
        }
    }

    private func emitLevelIfDue(rms: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelEmissionUptime >= 0.05 else { return }
        lastLevelEmissionUptime = now
        guard inSpeech else { return }
        let decibels: Float = rms > 0 ? 20 * log10(rms) : -120
        let normalized = min(1, max(0, (max(-60, decibels) + 60) / 60))
        DispatchQueue.main.async { [weak self] in
            self?.onInputLevel?(normalized)
        }
    }

    // Test seams: both of these had bugs that only appear with interleaved or
    // multichannel hardware, which unit tests can reproduce and a Mac with one
    // built-in microphone cannot.
    static func copyForTesting(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? { copy(buffer) }
    static func rmsForTesting(_ buffer: AVAudioPCMBuffer) -> Float { rms(of: buffer) }

    /// Copies the raw audio buffers rather than a fixed number of samples per
    /// channel. For interleaved formats the per-channel pointers alias one
    /// allocation with a stride, so copying `frameLength` contiguous values per
    /// channel overlapped the prefixes and dropped the rest of the audio.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in 0 ..< source.count {
            guard
                let sourceData = source[index].mData,
                let targetData = target[index].mData
            else { return nil }
            let bytes = min(Int(source[index].mDataByteSize), Int(target[index].mDataByteSize))
            memcpy(targetData, sourceData, bytes)
            target[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }

    /// Normalised RMS across every channel and every supported sample format.
    /// Reading channel 0 alone meant a microphone wired to a later input of a
    /// multichannel interface never tripped the threshold, and the integer
    /// formats always measured silence.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        let interleaved = buffer.format.isInterleaved
        let planes = interleaved ? 1 : channels
        let perPlane = interleaved ? channels : 1
        let stride = buffer.stride

        var sum: Double = 0
        var counted = 0

        func accumulate(_ value: Float) {
            sum += Double(value) * Double(value)
            counted += 1
        }

        if let data = buffer.floatChannelData {
            for plane in 0 ..< planes {
                let samples = data[plane]
                for frame in 0 ..< frames {
                    for channel in 0 ..< perPlane {
                        accumulate(samples[frame * stride + channel])
                    }
                }
            }
        } else if let data = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            for plane in 0 ..< planes {
                let samples = data[plane]
                for frame in 0 ..< frames {
                    for channel in 0 ..< perPlane {
                        accumulate(Float(samples[frame * stride + channel]) / scale)
                    }
                }
            }
        } else if let data = buffer.int32ChannelData {
            let scale = Float(Int32.max)
            for plane in 0 ..< planes {
                let samples = data[plane]
                for frame in 0 ..< frames {
                    for channel in 0 ..< perPlane {
                        accumulate(Float(samples[frame * stride + channel]) / scale)
                    }
                }
            }
        } else {
            return 0
        }

        guard counted > 0 else { return 0 }
        return Float((sum / Double(counted)).squareRoot())
    }
}
