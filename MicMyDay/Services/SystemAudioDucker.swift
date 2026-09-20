import AudioToolbox
import CoreAudio
import Foundation
import os

/// Fades whatever else is playing down while a dictation is running, and back
/// up afterwards.
///
/// macOS gives a sandboxed app no way to duck another app specifically, so this
/// works on the default output device's own volume. That has consequences worth
/// being deliberate about:
///
/// - It silences *everything*, including MicMyDay's own cues, so the caller
///   restores before playing the finishing tone rather than after.
/// - Leaving the volume down would be a genuinely bad bug, so the original is
///   restored on every exit path, including app termination, and `isDucked`
///   never survives a failure to write.
/// - If the volume has moved since we set it, the user has taken over and we
///   leave it alone rather than yanking it back.
#if DEBUG
/// Wall-clock trace of the cue-to-duck path, written to a file because this
/// machine's `log show` returns nothing for the app. Debug builds only; every
/// call site is also compiled out of release.
enum DuckTrace {
    private static let start = ContinuousClock.now
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("duck-trace.txt")
    static func mark(_ label: String) {
        let line = "\(start.duration(to: .now))  \(label)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif

@MainActor
final class SystemAudioDucker {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "AudioDucker"
    )

    /// The dip at the start of a recording, which is heard rather than noticed.
    ///
    /// This is a duration because a fade is a duration: it is the shape of the
    /// effect itself, not a wait for something else to finish. Nothing is being
    /// sequenced behind it. The caller starts the dip when the opening cue
    /// reports that it has been heard, so this number never has to be large
    /// enough to let the cue through, and changing the cue cannot invalidate it.
    ///
    /// Every fade runs in this many steps; the caller chooses how long the
    /// whole fade takes. Sixty milliseconds is the default, by the user's
    /// ear: a fifth of a second was heard as the volume being turned down too
    /// slowly once the fade's start point was right, and a tenth still was.
    /// The old worry that a very short fade reads as the music being cut off
    /// belonged to the earlier linear curve; the exponential one below still
    /// fades at these lengths.
    ///
    /// Every sleep names an explicit tolerance. Without one the scheduler is
    /// free to coalesce these very short waits with other work and hand back
    /// far later than asked, which turned a fade meant to last a fifth of a
    /// second into one that took closer to two.
    private static let fadeOutSteps = 6
    private static let defaultFadeOut: Duration = .milliseconds(60)
    /// Coming back is deliberately not symmetric with going down.
    ///
    /// Our own finishing tone plays through the very device we are holding
    /// down, so any ramp on the way back swallows the front of that tone and
    /// the whole stop gesture feels sluggish. The volume therefore jumps most
    /// of the way back synchronously, before the tone is asked for, and only
    /// the last part is ramped, purely so a track that was playing does not
    /// click. Twenty milliseconds is below the threshold where a restore reads
    /// as a fade at all.
    private static let restoreJump: Float = 0.75
    /// How often `restoreGradually` writes. Fifty milliseconds is below the
    /// point where consecutive volume writes are heard as separate events.
    private static let restoreUpStep: Duration = .milliseconds(50)
    private static let fadeInSteps = 3
    private static let fadeInStep: Duration = .milliseconds(7)
    private static let tolerance: Duration = .milliseconds(2)

    /// How far down the fade has come after `step` of `steps`, as a fraction of
    /// the original volume.
    ///
    /// Exponential, because equal steps in level are heard as equal steps in
    /// loudness only when the level falls by a constant factor each time. The
    /// previous shape held the level up early and dropped late, and a trace on
    /// a real dictation showed the volume still at half two thirds of the way
    /// through the fade: the duck was heard long after it had started. Here the
    /// first step is already clearly quieter, so the duck is heard to begin the
    /// moment it begins.
    ///
    /// Never reaches zero on its own; the caller writes an exact zero after the
    /// final step, because no exponential does.
    nonisolated static func fadeOutFraction(step: Int, of steps: Int) -> Float {
        guard step > 0 else { return 1 }
        let progress = Float(step) / Float(steps)
        return pow(10, -2 * progress)
    }

    /// What `unduck` should do, given the volume now and the one we last wrote.
    ///
    /// Separated from the Core Audio calls so the decision can be tested. Every
    /// case here has been a bug or nearly one: leaving the volume down is the
    /// worst thing this class can do, and yanking it back after the user has
    /// deliberately changed it is the second worst.
    nonisolated enum Restoration: Equatable {
        /// The user moved the slider while we held it down. Leave it.
        case leaveAlone
        /// Nothing audible had happened yet, so put it back with no ceremony.
        case setDirectly
        /// Jump most of the way back, then ramp the rest.
        case jumpThenRamp
    }

    nonisolated static func restoration(now: Float, weLeftItAt ours: Float, original: Float) -> Restoration {
        // Anything but where we left it means somebody else has been here.
        guard abs(now - ours) <= 0.05 else { return .leaveAlone }
        // The recording ended before the dip got going, which is common: a
        // two-word dictation is shorter than the fade. Ramping back from a
        // level we never reached would add the very dip that did not happen.
        guard ours < original * 0.99 else { return .setDirectly }
        return .jumpThenRamp
    }

    /// What the volume was before we touched it, and which device it belonged
    /// to. Nil whenever we are not holding anything down.
    private var restore: (device: AudioDeviceID, volume: Float)?
    private var fadeTask: Task<Void, Never>?
    /// The last level this class wrote, so a volume found somewhere unexpected
    /// can be told apart from one we put there ourselves. See `unduck`.
    private var lastSetVolume: Float?
    /// What the device reported holding after our last finished fade. Kept
    /// beside the requested value because neither alone is trustworthy: some
    /// hardware snaps a write to a coarser step, so the readback differs from
    /// the request with nobody touching anything, and Core Audio may apply a
    /// write asynchronously, so a readback taken straight after it can still
    /// be the old level. A volume counts as the user's doing only when it
    /// matches neither.
    ///
    /// Valid only while the terminal write it confirmed is still the newest
    /// write: the moment another fade starts, it is cleared. Left standing it
    /// did the opposite of its job, vouching for a volume the user had in
    /// fact just set because their choice happened to land near the stale
    /// record.
    private var lastConfirmedVolume: Float?

    var isDucked: Bool { restore != nil }

    /// Fades the current output device down to `targetFraction` of the
    /// volume it had before the first call, all the way to silence by
    /// default.
    ///
    /// The first call captures the device and its volume; a later call with a
    /// lower target deepens the same duck from wherever the last write left
    /// it, without capturing again, which is how the dip under the opening
    /// cue becomes silence when the cue ends. Does nothing if the device has
    /// no settable volume, which is the case for some aggregate and
    /// digital-only devices; there is no sensible fallback and failing
    /// quietly is better than refusing to record.
    func duck(
        to targetFraction: Float = 0,
        over duration: Duration = SystemAudioDucker.defaultFadeOut
    ) {
        #if DEBUG
        DuckTrace.mark("duck(to: \(targetFraction)) entered")
        #endif
        if restore == nil {
            guard let device = Self.defaultOutputDevice(),
                  Self.canSetVolume(device),
                  let current = Self.volume(device),
                  current > 0.001
            else { return }
            restore = (device, current)
            lastSetVolume = current
        } else if let (device, _) = restore,
                  let last = lastSetVolume,
                  let now = Self.volume(device),
                  abs(now - last) > 0.05,
                  abs(now - (lastConfirmedVolume ?? last)) > 0.05 {
            // The user reached for the volume while we held it part-way down.
            // Their choice wins from here: no further writes, but the capture
            // and the last-written level stay, because `unduck` needs both to
            // reach the same conclusion.
            fadeTask?.cancel()
            return
        }
        guard let (device, original) = restore else { return }

        let target = original * max(0, targetFraction)
        let start = lastSetVolume ?? original
        // Deepening to where we already are, or above it, is not a fade; and
        // a fade over no time at all would divide by zero further down.
        guard target < start - 0.001, duration > .zero else { return }
        #if DEBUG
        DuckTrace.mark("duck(to: \(targetFraction)) Core Audio queries done")
        #endif
        let stepLength = duration / Self.fadeOutSteps
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            // Every step sleeps until an absolute deadline measured from here,
            // not for a relative interval. This code runs on the main actor
            // while the recording is starting up, and a trace showed each
            // relative 15 ms sleep actually taking 26 to 45 ms under that
            // load, stretching a 180 ms fade past 400. A late wakeup against
            // an absolute deadline costs only itself; it cannot accumulate.
            // A wakeup so late that whole steps are due skips to the newest
            // one rather than replaying stale levels in a burst.
            let started = ContinuousClock.now
            var step = 1
            while step <= Self.fadeOutSteps {
                guard !Task.isCancelled else { return }
                let level = target + (start - target)
                    * Self.fadeOutFraction(step: step, of: Self.fadeOutSteps)
                // The confirmation belongs to the previous fade's terminal
                // write; this write supersedes it. Cleared here, at the first
                // actual write, and not when the fade was merely created: a
                // fade cancelled before it ever wrote must not destroy
                // evidence that is still the newest truth.
                self?.lastConfirmedVolume = nil
                Self.setVolume(device, level)
                #if DEBUG
                DuckTrace.mark("fade step \(step)/\(Self.fadeOutSteps) wrote \(level)")
                #endif
                self?.lastSetVolume = level
                do {
                    try await Task.sleep(
                        until: started + stepLength * step,
                        tolerance: Self.tolerance,
                        clock: .continuous
                    )
                } catch {
                    return
                }
                let due = Int(started.duration(to: .now) / stepLength) + 1
                step = min(max(step + 1, due), Self.fadeOutSteps + 1)
            }
            // The exact target the exponential never reaches, written only if
            // nothing cancelled the fade while we slept.
            guard !Task.isCancelled else { return }
            Self.setVolume(device, target)
            #if DEBUG
            DuckTrace.mark("fade wrote final \(target)")
            #endif
            self?.lastSetVolume = target
            self?.lastConfirmedVolume = Self.volume(device)
            self?.log("ducked \(start) -> \(target) in \(started.duration(to: .now))")
        }
    }

    /// Fades back to whatever the volume was, unless the user has since moved
    /// it themselves.
    /// Brings the other audio back gradually, while the recording is still
    /// running.
    ///
    /// Used for the countdown before the maximum length: the ducker sets the
    /// output device's own volume, so at zero the app cannot be heard either,
    /// and a warning tone played into that silence is no warning at all.
    /// Fading up over the final seconds solves both halves at once. The room
    /// comes back to life, which is itself a signal that the take is ending,
    /// and each tick is louder than the one before it.
    ///
    /// The held original is released here: the fade ends at exactly the level
    /// `unduck` would have restored, so the stop that follows has nothing
    /// left to do.
    func restoreGradually(over duration: Duration) {
        guard let (device, original) = restore else { return }
        restore = nil
        fadeTask?.cancel()

        let start = Self.volume(device) ?? 0
        guard original > start + 0.001, duration > .zero else {
            Self.setVolume(device, original)
            return
        }

        // Written often enough to be a rise rather than a staircase.
        //
        // This used to reuse `fadeOutSteps`, a count chosen for a fade lasting
        // sixty milliseconds. Across five seconds those same six steps are six
        // jumps of a sixth of the volume each, one every 833ms, and the five
        // countdown ticks fall one per second: the two rates beat against each
        // other, so each tick lands at a different point on the staircase and
        // some arrive just before a jump they should have been after. Small
        // steps remove the beat, because there is no longer a staircase for a
        // tick to land in the wrong part of.
        let steps = max(Self.fadeOutSteps, Int(duration / Self.restoreUpStep))
        let stepLength = duration / steps
        fadeTask = Task { @MainActor [weak self] in
            // Absolute deadlines, as the fade down uses: a late wakeup then
            // costs only itself instead of stretching the whole ramp.
            let started = ContinuousClock.now
            var step = 1
            while step <= steps {
                guard !Task.isCancelled else { return }
                let level = start + (original - start) * Float(step) / Float(steps)
                self?.lastConfirmedVolume = nil
                Self.setVolume(device, level)
                self?.lastSetVolume = level
                do {
                    try await Task.sleep(until: started + stepLength * step)
                } catch {
                    return
                }
                step += 1
            }
            Self.setVolume(device, original)
            self?.lastSetVolume = original
        }
    }

    func unduck() {
        #if DEBUG
        DuckTrace.mark("unduck() entered")
        #endif
        guard let (device, original) = restore else { return }
        restore = nil
        fadeTask?.cancel()

        let now = Self.volume(device) ?? 0
        // Whether the user moved the slider while we held it down. Their choice
        // wins if they did.
        //
        // This used to ask whether the volume was below half the original,
        // which worked only because the fade finished in 66 milliseconds and so
        // was always over before anyone could stop. With any dip long enough
        // to be stopped mid-way, a short dictation ends part way down, and that
        // test would have read our own unfinished fade as the user reaching for
        // the keyboard, and left the volume where it was. Comparing against
        // what we last wrote says what was actually meant.
        // Whichever of the two records sits nearer to what is there now: the
        // requested value when the hardware applied it exactly, the readback
        // when the hardware snapped it. See `lastConfirmedVolume`.
        //
        // A stop landing inside the fade itself, on a device that applies
        // writes late, can read a level between two of our steps as the
        // user's and leave the volume down. Accepted for now: it needs a
        // manual stop within a fraction of a second of go-live on hardware
        // that lags, and every cure tried so far suppressed genuine takeovers
        // instead, which is worse.
        let ours = [lastSetVolume, lastConfirmedVolume]
            .compactMap { $0 }
            .min(by: { abs($0 - now) < abs($1 - now) }) ?? 0
        lastSetVolume = nil
        lastConfirmedVolume = nil
        switch Self.restoration(now: now, weLeftItAt: ours, original: original) {
        case .leaveAlone:
            log("left alone: volume moved to \(now) while ducked, we left it at \(ours)")
            return
        case .setDirectly:
            Self.setVolume(device, original)
            log("restored to \(original) without a ramp; the dip had barely begun")
            return
        case .jumpThenRamp:
            break
        }

        // Synchronously, before returning: whatever the caller does next, and
        // it is usually "play the stop tone", happens at an audible volume.
        Self.setVolume(device, original * Self.restoreJump)

        fadeTask = Task { [weak self] in
            let started = ContinuousClock.now
            for step in 1 ... Self.fadeInSteps {
                guard !Task.isCancelled else { return }
                let fraction = Self.restoreJump
                    + (1 - Self.restoreJump) * Float(step) / Float(Self.fadeInSteps)
                Self.setVolume(device, original * fraction)
                try? await Task.sleep(for: Self.fadeInStep, tolerance: Self.tolerance)
            }
            // Guarded like every other write after a sleep: a duck that began
            // during the last wait must not be undone by this restore.
            guard !Task.isCancelled else { return }
            Self.setVolume(device, original)
            self?.log("restored to \(original) in \(started.duration(to: .now))")
        }
    }

    /// Puts the volume back immediately, with no fade. For quitting, where
    /// there is no time left to be graceful about it.
    func restoreImmediately() {
        guard let (device, original) = restore else { return }
        restore = nil
        lastSetVolume = nil
        lastConfirmedVolume = nil
        fadeTask?.cancel()
        Self.setVolume(device, original)
    }

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
    }

    // MARK: - Core Audio

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            // The "virtual main" volume is the one the menu bar slider moves,
            // rather than a single channel's own gain.
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func canSetVolume(_ device: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }

    private static func volume(_ device: AudioDeviceID) -> Float? {
        var address = volumeAddress()
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func setVolume(_ device: AudioDeviceID, _ value: Float) {
        var address = volumeAddress()
        var clamped = min(max(value, 0), 1)
        let size = UInt32(MemoryLayout<Float>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &clamped)
    }
}
