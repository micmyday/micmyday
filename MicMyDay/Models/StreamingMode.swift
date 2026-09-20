import Foundation

/// How a transcript should appear while the provider is still producing it.
///
/// This streams the model's output once the recording has been sent, not audio
/// while you speak: the words arrive progressively instead of in one lump at
/// the end. Only providers whose API can stream support it, and local engines
/// cannot at all, so the setting is hidden when the selected engine has no
/// streaming path.
enum StreamingMode: String, CaseIterable, Identifiable, Codable {
    /// Wait for the whole transcript, then paste once. The original behaviour.
    case off
    /// Show the words arriving in MicMyDay's overlay, then paste once at the
    /// end. Nothing half-finished ever reaches the target app.
    case overlay
    /// Type each piece into the focused app as it arrives.
    case directPaste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .overlay: return "Show in the overlay"
        case .directPaste: return "Type into the app as it arrives"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "The transcript appears in one go when it is ready."
        case .overlay:
            return "Words appear in MicMyDay's overlay as the provider produces them, and the finished text is pasted once. Nothing unfinished reaches the app you are typing into."
        case .directPaste:
            return "Words are typed into the focused app as they arrive, leaving your clipboard untouched. Fastest to read, and Escape stops it. Two things to know: stopping partway leaves an unfinished sentence behind, and if the focus moves while the words are still arriving, the rest can land in whatever is focused then. MicMyDay stops as soon as it sees you click or type, but it cannot see a window move focus on its own."
        }
    }

    /// True when the target app receives text before the transcript is final.
    var writesPartialTextToTargetApp: Bool { self == .directPaste }
}

extension TranscriptionProviderKind {
    /// Whether this engine can stream its transcript.
    ///
    /// The OpenAI-compatible providers expose `stream=true` on
    /// `/audio/transcriptions`, which emits `transcript.text.delta` events.
    /// Apple Speech and the local engines return only a finished result, and
    /// Gemini's streaming lives behind a different (Live) API that MicMyDay
    /// does not use, so none of them can offer it.
    var supportsStreamingTranscription: Bool {
        switch self {
        // Apple's recogniser is the only one that takes a live stream, so it
        // is the only one where the words appear while the user is still
        // talking. The rest stream a finished recording back in pieces.
        case .appleSpeech, .openAI, .custom: return true
        case .whisper, .parakeet, .nemotron, .gemini: return false
        }
    }
}

/// Decides how much of an in-flight transcript is safe to paste yet.
///
/// A provider emits deltas a few characters at a time, and pasting each one
/// separately would thrash the clipboard, flood the target app with undo steps,
/// and split words in half. This holds back the text after the last space,
/// since that word may still be growing, and releases the settled text only
/// once enough has built up to be worth a paste.
struct StreamingPasteBuffer {
    /// Below this, the wait for more text is cheaper than another paste.
    static let minimumChunk = 24

    private var pending = ""

    /// Adds a fragment and returns the text that is now safe to paste, if any.
    mutating func append(_ delta: String) -> String? {
        pending += delta
        guard pending.count >= Self.minimumChunk else { return nil }
        // Everything up to and including the last whitespace has settled; the
        // characters after it may be the start of a longer word.
        guard let lastSpace = pending.lastIndex(where: { $0.isWhitespace }) else { return nil }
        let settled = String(pending[pending.startIndex ... lastSpace])
        pending = String(pending[pending.index(after: lastSpace)...])
        return settled.isEmpty ? nil : settled
    }

    /// Returns whatever is left once the stream has finished.
    mutating func drain() -> String? {
        defer { pending = "" }
        return pending.isEmpty ? nil : pending
    }
}

/// Mutable state for one streamed dictation.
///
/// A reference type because the delta callback escapes into the transcriber and
/// has to keep updating the same buffer as words arrive.
@MainActor
final class StreamingSession {
    var buffer = StreamingPasteBuffer()
    /// Everything handed to the target app so far, in order. The final delivery
    /// pastes only what comes after this, so nothing is ever pasted twice.
    private(set) var pasted = ""
    /// Set when a chunk could not be delivered. The remaining words are then
    /// left to the final delivery rather than scattered into whatever happens
    /// to have focus.
    var failed = false
    /// Set when the user cancels. Checked again immediately before each piece
    /// is typed, because a delivery can already be waiting on focus by then.
    var cancelled = false
    /// Set when streaming stops cleanly and the rest is left to the closing
    /// delivery, which is not a failure: everything typed so far is intact.
    fileprivate(set) var stopped = false

    /// Whether any more text may be written into the user's document.
    ///
    /// `stopped` counts here too. It is a clean stop rather than a failure, but
    /// it still means stop: it is set when something arrives that cannot be
    /// typed, and when the user touches the keyboard or mouse, at which point
    /// the destination is no longer known to be the one they dictated into.
    var shouldContinue: Bool { !failed && !cancelled && !stopped }

    /// Whether new pieces may still be queued.
    var acceptsMoreChunks: Bool { shouldContinue }

    /// Stops streaming without marking anything as broken.
    ///
    /// Used when a piece contains something that cannot be typed safely, such
    /// as a tab: the remainder goes to the closing paste instead, which handles
    /// those correctly.
    func stopStreaming() { stopped = true }

    /// True for text that must not be delivered as synthesized keystrokes.
    ///
    /// Control characters are commands, not text. A tab moves focus to the next
    /// field, so everything after it lands somewhere else entirely, with the
    /// process ID unchanged so no focus check can catch it. A newline submits
    /// many single-line fields. Backspace and delete actually remove characters
    /// the user already had: typing "…mnop\u{7F}after" leaves "…mno" and loses
    /// the rest. Anything in this class goes to the clipboard instead.
    static func mustNotBeTyped(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            if scalar.properties.generalCategory == .control { return true }
            // AppKit reserves this private-use block for function keys, so a
            // scalar from it is read as Home, Delete, an arrow key and so on
            // rather than as a character. U+F728 deleted an existing letter and
            // swallowed the rest of the text; U+F702 moved the caret.
            return Self.appKitFunctionKeys.contains(scalar.value)
        }
    }

    /// The private-use range AppKit maps its function keys onto.
    private static let appKitFunctionKeys: ClosedRange<UInt32> = 0xF700 ... 0xF8FF

    /// The last link in the delivery chain.
    private var tail: Task<Void, Never>?

    /// Queues one chunk for delivery.
    ///
    /// Every chunk goes through a single chain rather than its own task. Each
    /// paste writes the clipboard and then posts Command-V with a suspension in
    /// between, so two running concurrently would overwrite each other's
    /// clipboard and paste the same text twice while losing the other. Chaining
    /// on the previous task keeps them strictly in order.
    func enqueue(_ chunk: String, deliver: @escaping @MainActor (String) async -> String) {
        guard acceptsMoreChunks else { return }
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            guard self.shouldContinue else { return }
            // Recorded only once it has actually been typed, and only as much
            // as was typed. Counting it up front made words that never left the
            // queue look delivered, so the closing hand-over subtracted them
            // and they vanished from the transcript entirely.
            let landed = await deliver(chunk)
            self.pasted += landed
            if landed != chunk {
                // Part of the chunk did not make it. Where it stopped is known
                // exactly, so this is a clean stop rather than a failure: the
                // rest can still be handed over without repeating anything.
                self.stopped = true
            }
        }
    }

    /// Waits for every queued chunk to land before the final delivery runs.
    func drainQueue() async {
        await tail?.value
        tail = nil
    }

    /// The part of `whole` that has not been delivered yet.
    ///
    /// Returns nil when what was pasted is not a prefix of the finished text,
    /// which means the two have diverged and appending would corrupt the
    /// document; the caller falls back to the clipboard instead.
    func undelivered(of whole: String) -> String? {
        guard !pasted.isEmpty else { return whole }
        guard whole.hasPrefix(pasted) else { return nil }
        return String(whole.dropFirst(pasted.count))
    }
}
