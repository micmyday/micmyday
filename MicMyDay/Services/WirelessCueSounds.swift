import AVFoundation
import Foundation
import os

/// Plays the feedback cues on a wireless headset.
///
/// This file exists because getting a short tone to sound cleanly on AirPods,
/// at the moment a dictation starts, turned out to be genuinely hard. What
/// follows is what was established by testing on real hardware, written down so
/// that none of it has to be rediscovered.
///
/// ## What the hardware does
///
/// A Bluetooth headset is two devices on macOS: a stereo output for music, and
/// a mono input at a much lower rate for calls. The link can only be in one of
/// those modes at a time. Opening the microphone therefore tears down the music
/// route and builds a new headset route in its place, which takes on the order
/// of a second, and doing so again in reverse when the microphone is released.
///
/// Two consequences drive everything here:
///
/// 1. **A newly built route has a speaker that is not powered up yet.** The
///    first sound to arrive does the waking, and the waking tears it. That
///    tearing is heard as a crackle at the head of the tone.
/// 2. **Anything playing when a route is destroyed is destroyed with it.** A
///    cue that starts just before the microphone opens, or just before it is
///    released, is cut off or lost entirely.
///
/// ## What follows from that
///
/// The opening cue is played **at the keypress, before the microphone is
/// opened**, over the music route, which already exists and can be woken. It
/// therefore means "starting", and the overlay's spinner is what says when the
/// microphone is genuinely listening.
///
/// Playing it instead at the moment recording truly begins was tried, because
/// that is the more honest signal, and it crackled every single time. The
/// reason is finding 1: at that moment the headset route is seconds old. Waking
/// the music route beforehand does not help, because that is not the route the
/// cue will play on. This is not a fixable ordering problem, it is what the
/// hardware does, and it is why the cue sits where it sits.
///
/// The closing cue is the mirror image. Capture stops, but the microphone is
/// deliberately **held open** until that cue reports itself finished, because
/// releasing it switches the route back and destroys the cue mid-chime.
///
/// ## Why an inaudible signal comes first
///
/// A cue is preceded by a real waveform far below hearing. Digital silence was
/// tried first and did nothing at all: Bluetooth power management keys off an
/// actual signal, and a run of zero samples reads as no signal, so the speaker
/// stayed asleep and the tone went on doing the waking. A quiet real tone wakes
/// the link while being inaudible, and takes the tearing in place of the cue.
///
/// ## Why AVAudioPlayer, and not the alternatives
///
/// `NSSound` is what wired and built-in devices still use, and it is fine
/// there. It is not enough here: it offers no way to ready the hardware in
/// advance, and its playback call blocked for up to half a second on a
/// Bluetooth route.
///
/// `AVAudioPlayer` has `prepareToPlay()`, which allocates the buffers and
/// readies the path ahead of time. Players are built once, kept for the life of
/// the app, and re-primed after every use.
///
/// `AVAudioEngine` was tried and is **the wrong instrument**, which is worth
/// recording because it looks like the sophisticated choice. `AVAudioEngine`
/// builds an aggregate device out of the headset's separate input and output
/// halves as soon as its output graph is touched. The capture engine has
/// already built one, so a second engine means two aggregates over one headset,
/// which fight: the log fills with route reconfigurations and cues render into
/// a device that is no longer live. That produced the all-or-nothing symptom
/// where every cue in a dictation was silent, or none was.
///
/// ## Threading
///
/// Everything runs on one serial queue. A cue took up to half a second to start
/// on a Bluetooth route, and on the main thread that stopped the overlay from
/// painting at all: the interface froze for five seconds while a tone was asked
/// for. Nothing here may move back to the main actor.
///
/// ## Ordering is on events
///
/// Steps wait for the previous one to report completion, not for a duration
/// that looked long enough on one machine. Timers appear only as fallbacks, set
/// well past any plausible real duration, so that a sound which never reports
/// cannot wedge a dictation.
///
final class WirelessCueSounds: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "WirelessCues"
    )

    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "com.micmyday.app.wireless-cues", qos: .userInitiated)

    private var players: [Cue: AVAudioPlayer] = [:]
    private var finishedHandlers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    private let delegate = CueDelegate()

    enum Cue: Hashable, Sendable {
        case silentWake
        case recordingStart
        case completion
        case failure
        case processingStart
        case waitingPulse
    }

    init(sounds: [Cue: (data: Data, volume: Float)]) {
        delegate.owner = self
        queue.async { [self] in
            for (cue, sound) in sounds {
                guard let player = try? AVAudioPlayer(data: sound.data) else {
                    log("could not build the \(cue) cue")
                    continue
                }
                player.volume = sound.volume
                player.delegate = delegate
                // The whole point: buffers allocated and hardware readied now,
                // not in the middle of the first tone.
                player.prepareToPlay()
                players[cue] = player
            }
        }
    }

    /// Re-primes every cue, so the next one does not pay to wake the hardware.
    ///
    /// Worth calling whenever a dictation is likely, because priming an
    /// already-primed player costs nothing while a cold one costs a crackle.
    func prepare() {
        queue.async { [self] in
            for player in players.values where !player.isPlaying {
                player.prepareToPlay()
            }
        }
    }

    /// Plays a cue. `whenFinished`, if given, runs when the sound has finished.
    func play(_ cue: Cue, whenFinished: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard let player = players[cue] else {
                whenFinished?()
                return
            }
            if player.isPlaying { player.stop() }
            player.currentTime = 0
            if let whenFinished {
                finishedHandlers[ObjectIdentifier(player)] = whenFinished
            }
            guard player.play() else {
                log("the \(cue) cue would not play")
                finishedHandlers.removeValue(forKey: ObjectIdentifier(player))?()
                return
            }
        }
    }

    /// Stops a cue and releases anyone waiting on it.
    func stop(_ cue: Cue) {
        queue.async { [self] in
            guard let player = players[cue] else { return }
            if player.isPlaying { player.stop() }
            finishedHandlers.removeValue(forKey: ObjectIdentifier(player))?()
        }
    }

    fileprivate func playerFinished(_ player: AVAudioPlayer) {
        queue.async { [self] in
            let handler = finishedHandlers.removeValue(forKey: ObjectIdentifier(player))
            // Ready for next time before anyone is told, so a caller that
            // immediately plays another cue finds a primed player.
            player.prepareToPlay()
            handler?()
        }
    }

    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
    }
}

/// `AVAudioPlayer` reports completion through a delegate, which has to be an
/// `NSObject`, so it is this small forwarder.
private final class CueDelegate: NSObject, AVAudioPlayerDelegate {
    weak var owner: WirelessCueSounds?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        owner?.playerFinished(player)
    }
}
