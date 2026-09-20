import AppKit
import Foundation

/// Plays short, unobtrusive cues without relying on the macOS alert sound.
///
/// The tones are synthesized with a smooth attack and release so they sound
/// like chimes rather than clicks. Keeping the `NSSound` instances alive also
/// prevents playback from being cut off early.
@MainActor
final class FeedbackSoundPlayer {
    private struct Tone {
        let frequency: Double
        let duration: TimeInterval
        var attack: TimeInterval = 0.012
    }



    private static let sampleRate = 44_100

    private let recordingStartSound: NSSound?
    private let completionSound: NSSound?
    private let failureSound: NSSound?
    private let processingStartSound: NSSound?
    private let waitingPulseSound: NSSound?
    private let silentSound: NSSound?
    /// One short tick per second through the last few seconds of a take.
    private let countdownSound: NSSound?

    /// The wireless cues. Built up front and kept primed, because a Bluetooth
    /// speaker that has gone to sleep tears whichever sound wakes it.
    private let wirelessSounds: WirelessCueSounds

    /// The closing cue is the one a wireless dictation waits on before letting
    /// the microphone go, so its completion has to be observable.
    private var closingCue: NSSound?
    private var closingCueFinished: (() -> Void)?
    private var closingCueWatchdog: Timer?
    /// When a cue last played, which is when the output was last known awake.
    private var lastCueAt: ContinuousClock.Instant?


    /// Set while recording through a wireless headset. Cues then go through the
    /// engine-backed player, which survives the Bluetooth route changing under
    /// it and can say when a cue has really finished. Everything else keeps
    /// using NSSound exactly as before.
    var usesWirelessRoute = false

    /// Reports when the opening cue has actually been heard.
    ///
    /// `NSSound.play()` returns as soon as playback begins, so on the wired
    /// path nothing used to know when a cue ended. The ducking that follows it
    /// needs that moment, and the only honest source of it is the delegate.
    private let startCueCompletion = CueCompletion()

    private let recordingStartAttack: TimeInterval
    private let completionDuration: TimeInterval
    private let failureDuration: TimeInterval
    private var waitingTimer: Timer?
    private var waitingGeneration = 0

    init() {
        let recordingStartTones = [
            Tone(frequency: 523.25, duration: 0.12),
            Tone(frequency: 0, duration: 0.018),
            Tone(frequency: 659.25, duration: 0.17),
        ]
        let completionTones = [
            Tone(frequency: 659.25, duration: 0.13),
            Tone(frequency: 0, duration: 0.018),
            Tone(frequency: 523.25, duration: 0.22),
        ]
        // Low descending minor third: unmistakably "something went wrong",
        // clearly distinct from the rising start cue and the completion chime.
        let failureTones = [
            Tone(frequency: 392.00, duration: 0.16),
            Tone(frequency: 0, duration: 0.02),
            Tone(frequency: 311.13, duration: 0.26),
        ]

        // Pressed-stop acknowledgement: a soft descending pair, quieter than
        // the start cue so it reads as "heard you, working" rather than "done".
        let processingStartTones = [
            Tone(frequency: 587.33, duration: 0.10),
            Tone(frequency: 0, duration: 0.015),
            Tone(frequency: 493.88, duration: 0.14),
        ]
        // The heartbeat while transcribing: one short, quiet tick. Deliberately
        // a single low tone — anything melodic becomes maddening on repeat.
        let waitingPulseTones = [
            Tone(frequency: 415.30, duration: 0.055),
        ]

        // The first strike's rise, read from the tones themselves: a copied
        // number would rot silently the day the synthesis changes.
        recordingStartAttack = recordingStartTones.first?.attack ?? 0
        completionDuration = completionTones.reduce(0) { $0 + $1.duration }
        failureDuration = failureTones.reduce(0) { $0 + $1.duration }
        silentSound = NSSound(data: Self.makeWaveData(tones: [Tone(frequency: 0, duration: 0.03)]))
        // A single short tick, well above the start and completion cues and
        // shorter than either. It has to be recognisable a second later as
        // the same sound again, and it has to be over before the next one, so
        // that five of them read as a countdown rather than as an alarm.
        countdownSound = NSSound(data: Self.makeWaveData(tones: [
            Tone(frequency: 880.00, duration: 0.07),
        ]))
        recordingStartSound = NSSound(data: Self.makeWaveData(tones: recordingStartTones))
        completionSound = NSSound(data: Self.makeWaveData(tones: completionTones))
        failureSound = NSSound(data: Self.makeWaveData(tones: failureTones))
        processingStartSound = NSSound(data: Self.makeWaveData(tones: processingStartTones))
        waitingPulseSound = NSSound(data: Self.makeWaveData(tones: waitingPulseTones))
        wirelessSounds = WirelessCueSounds(sounds: [
            // Played the moment the shortcut is pressed, to wake the headset's
            // speaker so that the tone which follows does not have to.
            //
            // Deliberately not digital silence. A run of zero samples is what
            // this was at first, and it did nothing: Bluetooth power management
            // keys off an actual signal, and a stream of zeros reads as no
            // signal at all, so the speaker stayed asleep and the tone went on
            // being torn. This is a real waveform, far below hearing, which
            // wakes the link while being inaudible.
            .silentWake: (Self.makeWaveData(tones: [Tone(frequency: 60, duration: 0.6)], gain: 0.0015), 1.0),
            // The wireless opening cue carries its own moment of quiet in
            // front, so anything left over from the wake lands there rather
            // than on the note.
            .recordingStart: (Self.makeWaveData(tones: [Tone(frequency: 0, duration: 0.1)] + recordingStartTones), 0.55),
            .completion: (Self.makeWaveData(tones: completionTones), 0.55),
            .failure: (Self.makeWaveData(tones: failureTones), 0.55),
            .processingStart: (Self.makeWaveData(tones: processingStartTones), 0.42),
            .waitingPulse: (Self.makeWaveData(tones: waitingPulseTones), 0.18),
        ])
        recordingStartSound?.volume = 0.55
        completionSound?.volume = 0.55
        failureSound?.volume = 0.55
        processingStartSound?.volume = 0.42
        waitingPulseSound?.volume = 0.18
    }

    /// Acknowledges the stop press immediately, then ticks quietly until the
    /// transcript is delivered.
    ///
    /// Without this, pressing stop produced no sound at all until transcription
    /// and rewriting had both finished — several seconds of silence in which
    /// nothing tells the user the press registered.
    /// Ticks once. Called for each of the final seconds of a recording, so
    /// the limit arriving is heard rather than only seen.
    func playCountdownTick() {
        guard let countdownSound else { return }
        countdownSound.stop()
        countdownSound.play()
    }

    func startProcessing() {
        stopWaiting()
        recordingStartSound?.stop()
        if usesWirelessRoute {
            wirelessSounds.play(.processingStart)
        } else {
            _ = processingStartSound?.play()
        }
        lastCueAt = .now

        // First tick lands after the acknowledgement has finished, so the two
        // never overlap.
        let generation = waitingGeneration
        let timer = Timer(timeInterval: 1.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.waitingGeneration else { return }
                if self.usesWirelessRoute {
                    self.wirelessSounds.play(.waitingPulse)
                } else {
                    self.waitingPulseSound?.stop()
                    _ = self.waitingPulseSound?.play()
                }
            }
        }
        timer.fireDate = Date().addingTimeInterval(0.85)
        // Common mode so the ticks keep coming while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        waitingTimer = timer
    }

    /// Lets go of the wireless output graph. Called when a dictation is over,
    /// so an output device is not held open for nothing.
    func releaseWirelessRoute() {
        usesWirelessRoute = false
    }

    /// Plays the cue that ends a dictation, and reports when it is safe to let
    /// the microphone go.
    ///
    /// On a wireless headset the caller is holding the microphone open purely
    /// so this cue is not destroyed by the Bluetooth link switching back, so
    /// `whenFinished` must not run until the sound has actually finished. On
    /// every other device nothing is waiting and it runs at once.
    ///
    /// Two things settle it, whichever comes first: the sound's own delegate
    /// callback plus a short margin, because the callback reports the end of
    /// the sound data rather than the last sample leaving the headset, and a
    /// watchdog, because a cue played into a route that has gone away may never
    /// report anything at all.
    private func play(closing sound: NSSound?, duration: TimeInterval, whenFinished: (() -> Void)?) {
        guard usesWirelessRoute else {
            // Wired and built-in devices are unchanged: play it and carry on,
            // because nothing is waiting on the cue there.
            _ = sound?.play()
            whenFinished?()
            return
        }

        // On a wireless headset the caller is holding the microphone open only
        // so this cue is not destroyed by the Bluetooth link switching back, so
        // it must not be released until the cue has genuinely finished.
        settleClosingCue()
        closingCueFinished = whenFinished
        lastCueAt = .now

        // A fallback, not the mechanism: comfortably longer than the cue, and
        // there only so a sound that never reports cannot hold the microphone.
        let watchdog = Timer(timeInterval: duration + 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settleClosingCue() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        closingCueWatchdog = watchdog

        let cue: WirelessCueSounds.Cue = sound === failureSound ? .failure : .completion
        wirelessSounds.play(cue) { [weak self] in
            Task { @MainActor in self?.settleClosingCue() }
        }
    }

    /// Runs the waiting caller exactly once and forgets the cue.
    private func settleClosingCue() {
        closingCueWatchdog?.invalidate()
        closingCueWatchdog = nil
        guard let finished = closingCueFinished else { return }
        closingCueFinished = nil
        finished()
    }

    func stopWaiting() {
        // Ticks already queued on the main actor can still run after the timer
        // is invalidated. On a wireless route one of those would stop the
        // closing cue that has just started, so they are stamped and dropped.
        waitingGeneration += 1
        waitingTimer?.invalidate()
        waitingTimer = nil
        waitingPulseSound?.stop()
        processingStartSound?.stop()
    }

    /// Fires the start cue and returns at once.
    ///
    /// This used to wait out the cue, roughly 350ms, so the microphone could
    /// not record it. That put a third of a second between pressing the
    /// shortcut and anything happening, on every single dictation, which is far
    /// worse than a faint chime at the head of the audio that no engine
    /// transcribes into words.
    /// Plays the opening cue on a wireless headset and returns when it has
    /// finished sounding.
    ///
    /// Every step waits for the one before it to report completion, rather than
    /// for a length of time somebody guessed. That matters because the guesses
    /// were the fragile part: a wake allowance that is generous on this Mac is
    /// not necessarily generous on a slower one, and a cue that overlaps the
    /// microphone opening is a race whose outcome depends on system load.
    ///
    /// The silent wake comes first because a Bluetooth output powers down when
    /// nothing has played for a while, and the first sound afterwards is torn
    /// by the wake. Silence takes that damage instead, and nobody hears it.
    /// Then the chime plays in full. Only then may the caller open the
    /// microphone, whose profile switch would otherwise cut the chime short.
    /// Sounds the opening cue on a wireless headset, at the keypress.
    ///
    /// An inaudible signal goes first and wakes the speaker, and the tone
    /// follows on its completion. Waking tears whichever sound does it, so
    /// something nobody can hear is made to do it.
    ///
    /// Both happen before the microphone is opened, and that ordering is the
    /// whole point. Opening the microphone destroys the music route and builds
    /// a fresh headset route in its place, and a route that has just been built
    /// has a speaker that is not up yet. Waking the old route does nothing for
    /// the new one, so a cue played at the moment recording truly begins is
    /// torn no matter what precedes it. That was tried, and it crackled every
    /// time.
    ///
    /// The cue therefore means "starting", not "speak now". The overlay's
    /// spinner is what says when the microphone is genuinely listening.
    /// `thenCueFinished` runs when the cue has finished sounding, so the
    /// overlay can keep its spinner until then and the two agree with each
    /// other rather than one arriving before the other.
    func wakeWirelessOutput(thenCueFinished: (@Sendable () -> Void)? = nil) {
        usesWirelessRoute = true
        wirelessSounds.prepare()
        wirelessSounds.play(.silentWake) { [weak self] in
            guard let self else {
                thenCueFinished?()
                return
            }
            self.wirelessSounds.play(.recordingStart) {
                thenCueFinished?()
            }
        }
        lastCueAt = .now
    }

    /// Plays the opening cue, calling `whenFinished` once it has been heard.
    ///
    /// `whenFinished` always runs exactly once, including when there is no cue
    /// to play or playback could not start: the caller is sequencing on this,
    /// and a callback that sometimes never arrives would be worse than none.
    ///
    /// Returns the instant the cue's first strike will have fully risen,
    /// captured at play-return, or nil when nothing sounded. The duck that
    /// follows the cue starts there: the strike answers the key at full
    /// volume, and everything after it is shaded down with the music. The
    /// attack length is an exact property of our own synthesized samples,
    /// not a tuned number.
    @discardableResult
    func playRecordingStart(whenFinished: (() -> Void)? = nil) -> ContinuousClock.Instant? {
        completionSound?.stop()
        // Cleared before stopping: `stop()` reports a finish of its own, and a
        // caller waiting on this cue must not be told the previous one's ending
        // was theirs.
        startCueCompletion.whenFinished = nil
        recordingStartSound?.stop()

        guard let sound = recordingStartSound else {
            whenFinished?()
            return nil
        }
        startCueCompletion.whenFinished = { _ in
            MainActor.assumeIsolated { whenFinished?() }
        }
        sound.delegate = startCueCompletion
        guard sound.play() else {
            // Nothing will be heard, so there is nothing to wait for.
            startCueCompletion.whenFinished = nil
            whenFinished?()
            return nil
        }
        lastCueAt = .now
        return ContinuousClock.now + .seconds(recordingStartAttack)
    }

    /// Wakes the audio output so the first cue of the day is not late.
    ///
    /// CoreAudio powers the output down when nothing has played for a while,
    /// and the first `play()` after that pays for waking it. A silent sound
    /// does the waking without being heard.
    func prewarm() {
        silentSound?.volume = 0
        _ = silentSound?.play()
        // Re-primes the wireless cues too, so the first one after a pause does
        // not have to wake the headset itself.
        wirelessSounds.prepare()
    }

    /// `whenFinished` runs once the chime has actually finished on a wireless
    /// headset, which is when it is safe to let the microphone go and the route
    /// switch back. On every other device it runs immediately: nothing is
    /// waiting on it there.
    func playCompletion(whenFinished: (() -> Void)? = nil) {
        stopWaiting()
        recordingStartSound?.stop()
        completionSound?.stop()
        play(closing: completionSound, duration: completionDuration, whenFinished: whenFinished)
    }

    /// A dictation attempt ended without inserting text. Making failure
    /// audible matters most when the user is in another window and would
    /// otherwise keep talking to a recording that no longer exists.
    func playFailure(whenFinished: (() -> Void)? = nil) {
        stopWaiting()
        recordingStartSound?.stop()
        completionSound?.stop()
        failureSound?.stop()
        play(closing: failureSound, duration: failureDuration, whenFinished: whenFinished)
    }

    /// The cues as floating point samples, for the wireless player, which
    /// schedules buffers rather than playing files. Same waveform, same
    /// envelope: the two routes must sound identical.
    private static func makeSamples(tones: [Tone], gain: Double) -> [Float] {
        makeAmplitudes(tones: tones).map { Float($0 * gain) }
    }

    private static func makeAmplitudes(tones: [Tone]) -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(Int(tones.reduce(0) { $0 + $1.duration } * Double(sampleRate)))

        for tone in tones {
            let sampleCount = max(1, Int(tone.duration * Double(sampleRate)))
            guard tone.frequency > 0 else {
                samples.append(contentsOf: repeatElement(0, count: sampleCount))
                continue
            }

            let attackSamples = min(sampleCount / 2, Int(tone.attack * Double(sampleRate)))
            let releaseSamples = min(sampleCount / 2, Int(0.055 * Double(sampleRate)))

            for sampleIndex in 0 ..< sampleCount {
                let time = Double(sampleIndex) / Double(sampleRate)
                let attack = attackSamples == 0
                    ? 1
                    : min(1, Double(sampleIndex) / Double(attackSamples))
                let samplesRemaining = sampleCount - sampleIndex - 1
                let release = releaseSamples == 0
                    ? 1
                    : min(1, Double(samplesRemaining) / Double(releaseSamples))
                let envelope = attack * release
                let phase = 2 * Double.pi * tone.frequency * time
                let waveform = sin(phase) + (0.12 * sin(phase * 2))
                let normalized = max(-1, min(1, waveform / 1.12))
                samples.append(normalized * envelope * 0.32)
            }
        }
        return samples
    }

    private static func makeWaveData(tones: [Tone], gain: Double = 1) -> Data {
        var samples: [Int16] = []
        samples.reserveCapacity(Int(tones.reduce(0) { $0 + $1.duration } * Double(sampleRate)))

        for tone in tones {
            let sampleCount = max(1, Int(tone.duration * Double(sampleRate)))
            guard tone.frequency > 0 else {
                samples.append(contentsOf: repeatElement(0, count: sampleCount))
                continue
            }

            let attackSamples = min(sampleCount / 2, Int(tone.attack * Double(sampleRate)))
            let releaseSamples = min(sampleCount / 2, Int(0.055 * Double(sampleRate)))

            for sampleIndex in 0 ..< sampleCount {
                let time = Double(sampleIndex) / Double(sampleRate)
                let attack = attackSamples == 0
                    ? 1
                    : min(1, Double(sampleIndex) / Double(attackSamples))
                let samplesRemaining = sampleCount - sampleIndex - 1
                let release = releaseSamples == 0
                    ? 1
                    : min(1, Double(samplesRemaining) / Double(releaseSamples))
                let envelope = attack * release
                let phase = 2 * Double.pi * tone.frequency * time
                let waveform = sin(phase) + (0.12 * sin(phase * 2))
                let normalized = max(-1, min(1, waveform / 1.12))
                samples.append(Int16(normalized * envelope * 0.32 * gain * Double(Int16.max)))
            }
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataByteCount = samples.count * bytesPerSample
        var data = Data()
        data.reserveCapacity(44 + dataByteCount)

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1)) // Linear PCM
        data.appendLittleEndian(UInt16(1)) // Mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample * 8))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataByteCount))

        for sample in samples {
            data.appendLittleEndian(sample)
        }

        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}



/// Turns `NSSound`'s delegate callback into a one-shot closure.
///
/// `NSSound` reports the end of a sound only this way; `play()` returns at the
/// start of it, and the sound's nominal duration is a property of the samples
/// rather than of the machine that plays them. Anything that has to happen
/// after a cue has been heard hangs off here.
private final class CueCompletion: NSObject, NSSoundDelegate {
    /// Cleared before it is called, so a sound that reports twice, which
    /// `stop()` followed by a natural end can do, cannot run it twice.
    var whenFinished: ((Bool) -> Void)?

    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        let handler = whenFinished
        whenFinished = nil
        handler?(finished)
    }
}
