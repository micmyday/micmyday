import AVFoundation
import Foundation

/// A transcriber that works while the user is still speaking.
///
/// The dictation flow treats every one of these identically: buffers go in
/// from the audio thread as they are captured, partial text comes back for
/// the overlay's preview, and on stop the transcriber either supplies the
/// complete final text or returns an empty string, which sends the dictation
/// down the ordinary path of transcribing the recorded file. The file is
/// always written regardless, so a live engine can only ever add speed, never
/// lose words.
protocol LiveTranscribing: AnyObject, Sendable {
    /// Begins recognising. Buffers handed to `append` from this point on are
    /// transcribed as they arrive.
    func start()

    /// Feeds one captured buffer. Called on the audio thread; must not block.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Closes the stream and waits for the final text, giving up after
    /// `limit`. An empty return means the live result is incomplete and the
    /// recording must be transcribed instead.
    func finishOrGiveUp(after limit: Duration) async -> String

    /// Abandons recognition without waiting, for a cancelled dictation.
    func cancel()

    /// The text so far, for a cancellation that wants to preserve it.
    var currentText: String { get }

    /// How long a stop may wait for this engine's final text. Bounded per
    /// engine because the work outstanding at stop differs.
    var finishBudget: Duration { get }
}

extension LiveSpeechTranscriber: LiveTranscribing {
    /// The recogniser normally reports its final revision within a moment.
    var finishBudget: Duration { .seconds(3) }
}
