import AppKit
import CoreGraphics
import Foundation
import OSLog

enum TextInjectionError: LocalizedError {
    case clipboardWriteFailed
    /// An edit needs to type over the selection, and typing needs permissions
    /// this Mac has not given.
    case accessibilityUnavailable
    /// The edited passage contains characters that cannot be typed without
    /// doing something other than inserting them: a tab moves focus, a newline
    /// can submit the field.
    case cannotBeTyped
    /// Part of the edit reached the document and the rest did not, which leaves
    /// the user's passage replaced by a fragment.
    case partiallyTyped(delivered: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            return "macOS could not copy the transcription to the clipboard."
        case .accessibilityUnavailable:
            return "Editing by voice needs Accessibility access, so nothing was changed."
        case .cannotBeTyped:
            return "The edited text contains tabs or line breaks, which cannot be typed into another app safely. Your text was left as it was."
        case let .partiallyTyped(delivered, expected):
            return "Only \(delivered) of \(expected) characters reached the app, so the edit is incomplete. Undo in that app to put it back."
        }
    }
}

enum TextDeliveryResult: Equatable {
    case pastedAndCopied
    /// Pasted, and the user's own clipboard put back afterwards. The transcript
    /// is no longer available for a second Command-V, which is the trade the
    /// setting makes.
    case pasted
    case copiedOnly
    /// Reached the app, but the clipboard could not be updated. Only streaming
    /// can produce this: it types the text rather than pasting it, so delivery
    /// does not depend on the clipboard write succeeding.
    case insertedNotCopied
    /// Part of the transcript was typed and the clipboard holds only what is
    /// still missing, so pasting appends rather than replaces.
    case remainderCopied
    /// Part of the transcript was typed, but the finished text no longer starts
    /// with it, so the clipboard holds the whole transcript as a replacement.
    /// Pasting this without removing the typed part would duplicate it.
    case replacementCopied

    var statusMessage: String {
        switch self {
        case .insertedNotCopied:
            return "Typed into the focused app; the clipboard could not be updated"
        case .remainderCopied:
            return "Partly typed; the rest is on the clipboard"
        case .replacementCopied:
            return "Partly typed; the clipboard holds the full text to replace it"
        case .pastedAndCopied:
            return "Pasted into the focused app and copied to clipboard"
        case .pasted:
            return "Pasted into the focused app, leaving no copy on the clipboard"
        case .copiedOnly:
            return "Copied to clipboard"
        }
    }
}

final class TextInjector {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "TextDelivery"
    )

    static var isAccessibilityTrusted: Bool {
        // Event posting has its own TCC permission. General AX APIs are not
        // supported in an App Sandbox; MicMyDay only needs to post a paste.
        CGPreflightPostEventAccess()
    }

    /// Whether the user has allowed it, as opposed to whether this process can
    /// act on it.
    ///
    /// Post-event access is resolved once per process, so a grant made while
    /// MicMyDay is running leaves `isAccessibilityTrusted` false until it is
    /// restarted, however many times it is asked. That is indistinguishable
    /// from never having granted it at all, which is why somebody who has just
    /// switched the toggle on is told the app cannot see it.
    ///
    /// This reads the trust database instead, which does change under a
    /// running process. It answers only "has the user done their part", never
    /// "can we paste yet": pasting still needs the restart.
    static var isAccessibilityAllowedInSystemSettings: Bool {
        AXIsProcessTrusted()
    }

    /// Injectable so tests can pin the permission state instead of inheriting
    /// whatever TCC happens to say on the machine running them, and use a
    /// private pasteboard instead of clobbering the user's clipboard.
    private let accessibilityTrusted: () -> Bool
    private let pasteboard: NSPasteboard

    init(
        accessibilityTrusted: @escaping () -> Bool = { TextInjector.isAccessibilityTrusted },
        pasteboard: NSPasteboard = .general
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.pasteboard = pasteboard
    }

    @MainActor
    func insert(
        _ rawText: String,
        targetPID: pid_t?,
        appendTrailingSpace: Bool,
        autoSend: AutoSendKey = .off,
        restoreClipboard: Bool = false,
        /// Given when the caller has already borrowed the clipboard and holds
        /// the user's own contents. Reading a selection does exactly that, and
        /// without this the clipboard captured here would be the selection the
        /// edit just copied rather than what the user had before it.
        restoring: ClipboardContents? = nil,
        /// The change count `restoring` was captured at, so a copy the user
        /// made in between is recognised as theirs and left alone.
        restoringIfUnchangedFrom: Int? = nil,
        /// Types the characters instead of pasting them.
        ///
        /// Pasting is faster and more robust for a long transcript, but it has
        /// one hazard that cannot be removed: `CGEvent.post` returns before the
        /// target has read the pasteboard, nothing reports when it does, and so
        /// putting the user's clipboard back afterwards is always a race. Lose
        /// it and the app pastes the old clipboard instead.
        ///
        /// For an ordinary dictation that is a wrong paste, recoverable with
        /// the insert-again shortcut. For a voice edit it would replace the
        /// user's selected passage with unrelated clipboard contents, and
        /// auto-send could submit it. There the race is not worth bounding, so
        /// the clipboard is not involved at all.
        typeInsteadOfPasting: Bool = false,
        /// The text is a preserved exact replacement (a kept edit); trimming it
        /// or appending a space would re-break whitespace that was deliberately
        /// carried through.
        insertExactly: Bool = false,
        shouldProceed: @MainActor () -> Bool = { true }
    ) async throws -> TextDeliveryResult {
        // An edit is put back exactly as it came out, whichever way it is
        // delivered. Keying this off the typing path was wrong twice over: a
        // multi-line passage is exactly the one that must keep its newline, and
        // exactly the one the typing path refuses — so the trim below undid the
        // whitespace fix for every selection it existed for.
        let exactReplacement = typeInsteadOfPasting || restoring != nil || insertExactly
        var text = exactReplacement ? rawText : rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.emptyResponse
        }
        if appendTrailingSpace, !exactReplacement, text.last?.isWhitespace != true {
            text.append(" ")
        }

        // Taken before the transcript replaces it, so it can be given back.
        if typeInsteadOfPasting {
            return try await typeOverSelection(
                text,
                targetPID: targetPID,
                borrowed: restoring,
                borrowedAt: restoringIfUnchangedFrom,
                autoSend: autoSend,
                shouldProceed: shouldProceed
            )
        }

        // What to give back afterwards.
        //
        // A caller that already borrowed the clipboard, which is what reading a
        // selection does, hands over both its snapshot and the count it took it
        // at. If the clipboard has moved on since then, the user copied
        // something during the dictation and *that* is what they expect back,
        // not the older snapshot: so it is captured fresh and the caller's is
        // discarded.
        let borrowed: ClipboardContents?
        if let restoring {
            let userCopiedSince = restoringIfUnchangedFrom.map { pasteboard.changeCount != $0 } ?? false
            borrowed = userCopiedSince ? captureClipboard() : restoring
        } else {
            borrowed = restoreClipboard ? borrowUserClipboard() : nil
        }
        // A one-off id, written alongside the text, so the restore can tell
        // this write from anything that replaced it.
        let sessionID = UUID().uuidString
        let wroteForRestore = borrowed != nil
        if wroteForRestore {
            guard writeForPaste(text, sessionID: sessionID) else {
                throw TextInjectionError.clipboardWriteFailed
            }
        } else {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw TextInjectionError.clipboardWriteFailed
            }
        }
        // Anything that writes the clipboard bumps this. Focusing the target
        // below suspends, and another app copying during that window would mean
        // Command-V pastes their content instead of the transcript, with
        // auto-send then submitting it.
        let writtenChangeCount = pasteboard.changeCount
        Self.logger.notice("Copied transcript to clipboard: characters=\(text.count)")

        guard accessibilityTrusted(), let targetPID else {
            Self.logger.notice("Automatic paste skipped; transcript remains on clipboard")
            if restoring != nil {
                if let borrowed {
                    giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount)
                }
                throw CancellationError()
            }
            return .copiedOnly
        }
        guard shouldProceed() else {
            Self.logger.notice("Automatic paste skipped; the dictation was already stopped")
            if restoring != nil {
                if let borrowed {
                    giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount)
                }
                throw CancellationError()
            }
            guard reclaimClipboardIfStillOurs(text, writtenChangeCount) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return .copiedOnly
        }
        guard await focusApplication(processIdentifier: targetPID) else {
            Self.logger.error("Automatic paste skipped; target pid \(targetPID) is unavailable")
            if restoring != nil, let borrowed {
                giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount)
                throw CancellationError()
            }
            // The wait above suspends, so the clipboard may have changed hands
            // in the meantime; the user must not be sent to it for a transcript
            // that is no longer there.
            guard reclaimClipboardIfStillOurs(text, writtenChangeCount) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return .copiedOnly
        }
        // Escape can land during the focus wait above. The words are already on
        // the clipboard, so the user loses nothing by stopping here.
        guard shouldProceed() else {
            Self.logger.notice("Automatic paste skipped; the dictation was cancelled")
            // For an edit, "it is on the clipboard" is never the right ending:
            // the clipboard was only borrowed to carry the passage, and the
            // user's own content has to go back through the gate.
            if restoring != nil, let borrowed {
                giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount)
                throw CancellationError()
            }
            // The focus wait suspends, so the clipboard may have changed hands.
            // Sending the user to it for a transcript that is no longer there
            // would lose the dictation.
            guard reclaimClipboardIfStillOurs(text, writtenChangeCount) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return .copiedOnly
        }
        // Checked as the very last thing before Command-V: any earlier and a
        // copy during the remaining work would go unnoticed and paste someone
        // else's content, which auto-send could then submit.
        guard pasteboard.changeCount == writtenChangeCount else {
            Self.logger.notice("Automatic paste skipped; the clipboard changed before pasting")
            if restoring != nil {
                // Somebody else's copy owns the board now, and it stays. The
                // borrowed snapshot goes back through the gate, which will
                // decline for the same reason and park or drop per its rules.
                if let borrowed { giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount) }
                throw CancellationError()
            }
            // Something else owns the clipboard now, so the transcript is not
            // there and telling the user to press Command-V would be wrong.
            // Put it back, then report honestly.
            guard reclaimClipboardIfStillOurs(text, writtenChangeCount) else {
                throw TextInjectionError.clipboardWriteFailed
            }
            return .copiedOnly
        }
        guard postPasteShortcut() else {
            Self.logger.error("Automatic paste skipped; macOS could not create paste events")
            if restoring != nil {
                if let borrowed {
                    giveBackBorrowed(borrowed, ifUnchangedFrom: writtenChangeCount)
                }
                throw CancellationError()
            }
            return .copiedOnly
        }

        Self.logger.notice("Posted paste shortcut to target pid \(targetPID)")

        // Only after a paste actually reached the app: sending on a
        // clipboard-only fallback would fire Return into whatever is focused
        // without the text ever arriving.
        var waitedForThePaste = false
        if let stroke = autoSend.keyStroke {
            // The paste has to land before Return, or the app sends an empty
            // field. Same reasoning as the focus settle above.
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                waitedForThePaste = true
            } catch {
                // Cancelled, so no wait happened. Recorded honestly rather
                // than swallowed: the restore below decides what to do based
                // on whether the paste has had time, and a wait that did not
                // happen must not be counted as one.
            }
            // Rechecked after the wait: Return is destructive and the user may
            // have pressed Escape during it.
            if shouldProceed(), !Task.isCancelled {
                postAutoSend(keyCode: stroke.keyCode, flags: stroke.flags, targetPID: targetPID)
            }
        }

        if let borrowed {
            await giveBackClipboard(
                borrowed,
                ours: text,
                sessionID: sessionID,
                alreadyWaited: waitedForThePaste
            )
            return .pasted
        }
        return .pastedAndCopied
    }

    /// Returns the user's own clipboard once the paste has been consumed.
    ///
    /// There is no event for that. `CGEvent.post` returns as soon as the event
    /// is queued, and the receiving app reads the pasteboard whenever it gets
    /// round to handling the keystroke; AppKit offers nothing that reports the
    /// read. So this is a wait, and it is a wait on purpose rather than a
    /// stand-in for an ordering that could have been observed.
    ///
    /// It is the same allowance the auto-send path above already makes, for the
    /// same reason, and where auto-send has run it has already been paid: that
    /// Return could not have been delivered before the paste it follows.
    ///
    /// This bounds the race rather than removing it. An app slow enough to
    /// still be holding the keystroke after a quarter of a second would read
    /// the restored clipboard and paste that instead, and with auto-send on it
    /// would then be submitted. Removing the race entirely means not putting
    /// the transcript on the clipboard at all, which means typing the
    /// characters rather than pasting them: correct, but slower on a long
    /// transcript and more easily disturbed. Pasting with a bounded wait is the
    /// better trade for the common case, and turning the setting off restores
    /// the old behaviour exactly.
    /// Puts the transcript back on the clipboard, but only if nobody else has
    /// claimed it since we wrote it there.
    ///
    /// These branches all end with "the paste did not happen, so the user will
    /// press Command-V themselves", and each used to make sure the transcript
    /// was there by writing it again. When the clipboard has moved on, that is
    /// somebody else's copy being thrown away. Reporting `copiedOnly` in that
    /// case would also be a lie, so the caller is told the write failed and
    /// says something honest instead.
    private func reclaimClipboardIfStillOurs(_ text: String, _ writtenChangeCount: Int) -> Bool {
        if pasteboard.changeCount == writtenChangeCount { return true }
        Self.logger.notice("Clipboard belongs to something else now; the transcript was not put back on it")
        return false
    }

    @MainActor
    private func giveBackClipboard(
        _ contents: ClipboardContents,
        ours text: String,
        sessionID: String,
        alreadyWaited: Bool
    ) async {
        if !alreadyWaited {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                // Cancelled. Restoring now would be restoring early, which is
                // the one thing this wait exists to prevent, but abandoning the
                // snapshot loses the user's clipboard outright. Detached, so it
                // outlives the cancellation and still finishes the wait: the
                // work is a single pasteboard write and nothing is waiting on
                // it.
                Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await MainActor.run { [weak self] in
                        self?.restoreIfStillOurs(contents, text: text, sessionID: sessionID)
                    }
                }
                return
            }
        }
        restoreIfStillOurs(contents, text: text, sessionID: sessionID)
    }

    @MainActor
    private func restoreIfStillOurs(_ contents: ClipboardContents, text: String, sessionID: String) {
        // A selection is being read by copy right now. Writing the user's old
        // clipboard back in that window makes the poll count it as the copy,
        // and the user's clipboard would be handed to the model as "the
        // selection". Parked instead of dropped, so the snapshot stays
        // reachable through the hold whichever restore eventually runs.
        guard !selectionCaptureActive else {
            park(contents)
            return
        }
        guard clipboardStillHoldsOurPaste(text, sessionID: sessionID) else {
            // Somebody wrote since. Behind one of our own writes the snapshot
            // is parked for that write's restore path to find; behind the
            // user's newer copy it is dropped, because it was already obsolete
            // the moment they copied, and parking it let a later capture hand
            // the stale content back out.
            Self.logger.notice("Clipboard not restored; it no longer holds this dictation's paste")
            if pasteboard.string(forType: PasteboardConvention.session) != nil {
                park(contents)
            }
            return
        }
        // Released only when the write actually landed: a failed restore has
        // put nothing back, and dropping the hold then would abandon the only
        // copy of the user's clipboard that still exists.
        if restore(contents) {
            releaseUserClipboard()
        }
    }

    /// Pastes one more piece of a transcript that is still arriving.
    ///
    /// Used only by direct-paste streaming. Unlike `insert` it adds no trailing
    /// space and sends no auto-send key: those belong to the last piece, and
    /// firing Return halfway through a sentence would submit it unfinished.
    /// Returns false if the chunk could not be delivered, which stops the
    /// stream rather than scattering the rest of the words somewhere else.
    /// Types a piece of a streamed transcript, returning exactly the part that
    /// reached the app.
    ///
    /// The return value is the delivered prefix rather than a yes/no, because a
    /// stop can land between batches. Knowing precisely how much arrived is
    /// what lets the caller hand over the rest without repeating or skipping
    /// anything.
    @MainActor
    func insertChunk(
        _ text: String,
        targetPID: pid_t?,
        shouldProceed: @MainActor () -> Bool = { true }
    ) async -> String {
        guard !text.isEmpty, accessibilityTrusted(), let targetPID else { return "" }
        // Typing these would move focus, submit the field or delete existing
        // text; the caller has to deliver them another way.
        guard !StreamingSession.mustNotBeTyped(text) else { return "" }
        // Checked before focusing: a stopped or cancelled dictation must not
        // drag the target app back in front of whatever the user moved to.
        guard shouldProceed() else { return "" }
        guard await focusApplication(processIdentifier: targetPID) else { return "" }
        // Focus can settle onto the wrong app, or the dictation can be
        // cancelled, during the wait above. This is the last moment before
        // characters become irreversible.
        guard shouldProceed() else { return "" }
        return await postUnicode(text, targetPID: targetPID, shouldProceed: shouldProceed)
    }

    /// Types text as synthesized key events, without touching the clipboard.
    ///
    /// Streaming delivers many small pieces in quick succession. Doing that
    /// through the clipboard cannot be made correct: posting Command-V returns
    /// before the receiving app has read the pasteboard, so the next piece
    /// overwrites what the app was about to paste, producing duplicated or
    /// missing text. It would also destroy whatever the user had copied. Typing
    /// the characters has neither problem.
    ///
    /// Runs on the main actor and never suspends, so the checks between batches
    /// cannot go stale midway.
    @MainActor
    private func postUnicode(
        _ text: String,
        targetPID: pid_t,
        shouldProceed: @MainActor () -> Bool
    ) async -> String {
        guard CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .hidSystemState) else {
            return ""
        }
        var delivered = ""
        for (index, batch) in Self.unicodeBatches(of: text).enumerated() {
            // A real suspension, not Task.yield(): cancellation and the user's
            // own key and mouse events are delivered through the main run loop,
            // and yielding can resume without the loop having run at all. A
            // short sleep lets them through, so Escape and a click into another
            // field are noticed within a batch rather than after the whole
            // chunk has been typed.
            if index > 0 { try? await Task.sleep(nanoseconds: 12_000_000) }
            // Re-checked per batch rather than once for the whole chunk: a
            // long chunk would otherwise keep typing well after the user
            // pressed Escape or switched away.
            guard shouldProceed() else { return delivered }
            // Re-checked per batch: focus can move between them.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                return delivered
            }
            var units = Array(batch.utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return delivered }
            // The event source reports the *current* hardware modifier state,
            // so a key the user happens to be holding would otherwise ride
            // along and turn dictated letters into shortcuts: Control-A jumps
            // to the start of the line instead of typing "a".
            keyDown.flags = []
            keyUp.flags = []
            Self.markAsSynthetic(keyDown, keyUp)
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            delivered += batch
        }
        return delivered
    }

    /// Splits text into UTF-16 runs small enough for one keyboard event.
    ///
    /// Long strings on a single event are delivered unreliably. Batches are cut
    /// on character boundaries so an emoji or accented letter is never split
    /// across two events, which would post two broken halves.
    static func unicodeBatches(of text: String, limit: Int = 16) -> [String] {
        var batches: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            // A batch that *starts* with a newline or tab is read by AppKit as
            // an editing command rather than text, and everything after it in
            // that batch is discarded. Giving each one its own event keeps the
            // words that follow.
            let isCommandLike = character.isNewline || character == "\t"
            if !current.isEmpty, isCommandLike || currentUnits + units > limit {
                batches.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
            if isCommandLike {
                batches.append(current)
                current = ""
                currentUnits = 0
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Puts the finished transcript on the clipboard.
    ///
    /// Streaming pastes in pieces, so without this the clipboard would keep
    /// only the final fragment.
    /// Replaces a selection by typing, so the clipboard is never involved.
    ///
    /// Used for a voice edit, where losing the paste/restore race would replace
    /// the user's passage with unrelated clipboard contents. Typing has its own
    /// hazards, all of which are handled here rather than shared with the
    /// streaming path, which has different rules.
    @MainActor
    private func typeOverSelection(
        _ text: String,
        targetPID: pid_t?,
        borrowed: ClipboardContents?,
        borrowedAt: Int?,
        autoSend: AutoSendKey,
        shouldProceed: @MainActor () -> Bool
    ) async throws -> TextDeliveryResult {
        // Whatever happens below, the clipboard the selection was read with is
        // the user's and goes back — unless they have copied something since,
        // in which case that newer copy is theirs and stays. Typing itself
        // never touches the clipboard, so the only writes since the borrow are
        // the user's own.
        defer {
            if let borrowed {
                giveBackBorrowed(borrowed, ifUnchangedFrom: borrowedAt)
            }
        }

        guard accessibilityTrusted(), let targetPID, CGPreflightPostEventAccess() else {
            // Nothing was typed and the selection is untouched. Saying so is
            // better than leaving the result on a clipboard the user did not
            // ask us to take.
            throw TextInjectionError.accessibilityUnavailable
        }
        // Tabs move focus and newlines submit forms, and here they would do it
        // instead of replacing the selection. An edited passage that contains
        // them cannot be typed at all, so it is refused rather than mangled.
        guard !StreamingSession.mustNotBeTyped(text) else {
            throw TextInjectionError.cannotBeTyped
        }
        guard shouldProceed() else { throw CancellationError() }
        // Brought back to front first, exactly as pasting does. The rewrite
        // takes long enough for another app to have activated itself, and
        // typing into whatever is frontmost would put the edit in the wrong
        // document entirely.
        guard await focusApplication(processIdentifier: targetPID) else {
            throw TextInjectionError.accessibilityUnavailable
        }
        guard shouldProceed() else { throw CancellationError() }

        let typed = await postUnicode(text, targetPID: targetPID, shouldProceed: shouldProceed)
        // Nothing at all reached the app: the selection is untouched, so this
        // is a clean stop, not a partial edit. Reporting it as partial told the
        // user to Undo, which would have reverted their own last change.
        guard !typed.isEmpty else { throw CancellationError() }
        // Anything short of all of it has replaced the user's passage with part
        // of the answer, which is worse than not having tried. There is no way
        // back from it, so it is reported rather than passed off as success,
        // and no auto-send follows a half-typed sentence.
        guard typed == text else {
            throw TextInjectionError.partiallyTyped(delivered: typed.count, expected: text.count)
        }
        if let stroke = autoSend.keyStroke, shouldProceed(), !Task.isCancelled {
            postAutoSend(keyCode: stroke.keyCode, flags: stroke.flags, targetPID: targetPID)
        }
        return .pasted
    }

    /// The user's clipboard, held while one of our pastes is still on the
    /// pasteboard waiting to be restored over.
    ///
    /// One snapshot, shared across pastes, because two pastes in quick
    /// succession otherwise launder the user's content away: the second one
    /// "borrows" a clipboard that still holds the first one's transcript, the
    /// first restore backs off on seeing the second's write, and the second
    /// then dutifully restores the first's transcript. Whatever was there
    /// before either of them is gone. Held here, a second paste reuses the
    /// snapshot the first took, and whichever restore finally runs returns the
    /// user's actual content.
    private var heldUserClipboard: ClipboardContents?
    /// True while an edit has borrowed the held snapshot. The board then
    /// legitimately carries unmarked content — the copied selection — and the
    /// staleness rule in `borrowUserClipboard` must not read that as the user
    /// having copied and throw the hold away.
    // Deliberately no loan or provenance flags here any more. Three review
    // rounds each replaced one clipboard-laundering interleaving with a
    // narrower one, because voice edits BORROWED this shared hold and every
    // pair of overlapping lifecycles needed its own rule. Edits now take a
    // private value-copy instead (see captureSelection), and the worst any
    // overlap can do is restore identical bytes twice.
    /// True while `captureSelection` is polling for its Command-C. A detached
    /// restore firing in that window writes the user's old clipboard back, and
    /// the poll would count that single change as the copy and hand the user's
    /// clipboard to the model as "the selection".
    private var selectionCaptureActive = false

    /// What a paste should give back afterwards: the snapshot already held if a
    /// previous paste has not returned it yet, a fresh capture otherwise —
    /// unless the clipboard currently holds one of our own paste writes with no
    /// snapshot held, in which case the user's content is unknowable and
    /// nothing is captured rather than capturing our own transcript as theirs.
    private func borrowUserClipboard() -> ClipboardContents? {
        let boardIsOurs = pasteboard.string(forType: PasteboardConvention.session) != nil
        let boardHasContent = !(pasteboard.pasteboardItems ?? []).isEmpty
        if heldUserClipboard != nil, !boardIsOurs, boardHasContent {
            // Our paste is gone and something else owns the board — which,
            // given nothing of ours writes without the marker, means the user
            // copied during the restore window. The hold is a snapshot of a
            // clipboard that no longer exists; reusing it would put older
            // content back over the copy they just made.
            Self.logger.notice("Dropping a stale clipboard hold; the user has copied since")
            heldUserClipboard = nil
        }
        if let held = heldUserClipboard { return held }
        guard !boardIsOurs else {
            Self.logger.notice("Clipboard holds one of our own pastes; nothing captured for restore")
            return nil
        }
        let captured = captureClipboard()
        heldUserClipboard = captured
        return captured
    }

    /// The snapshot has been returned (or deliberately abandoned); stop
    /// holding it so the next paste captures fresh.
    private func releaseUserClipboard() {
        heldUserClipboard = nil
    }

    /// Puts a parked hold back when the board still carries one of our own
    /// writes. A capture that failed leaves the transcript squatting on the
    /// board with the user's content parked; nobody else is coming to swap
    /// them, so the failed capture does it on its way out.
    @MainActor
    private func flushParkedRestoreIfBoardOurs() {
        guard let held = heldUserClipboard,
              pasteboard.string(forType: PasteboardConvention.session) != nil else { return }
        restore(held)
    }

    /// The one way anything gives borrowed clipboard content back.
    ///
    /// Three outcomes, decided here rather than at each call site, because
    /// every round of review found another caller applying its own subset of
    /// the rules: while a selection capture is polling, the content is PARKED
    /// into the hold (writing would be counted as the copy); when the board
    /// has moved on from `expectedChangeCount`, the give-back DECLINES (the
    /// board belongs to whoever wrote it); otherwise it restores.
    @MainActor
    func giveBackBorrowed(_ contents: ClipboardContents, ifUnchangedFrom expectedChangeCount: Int?) {
        guard !selectionCaptureActive else {
            park(contents)
            return
        }
        if let expectedChangeCount {
            // A decline means the board belongs to somebody else now. Who that
            // is decides the snapshot's fate: behind one of our own writes it
            // is parked, because that write's restore path needs to find it;
            // behind a FOREIGN write it is dropped, because the foreign write
            // is the user's newer copy and the snapshot is already obsolete —
            // parked anyway, a later capture could hand the stale content back
            // out and eventually restore it over the newer copy.
            if !restoreClipboard(contents, ifUnchangedFrom: expectedChangeCount) {
                if pasteboard.string(forType: PasteboardConvention.session) != nil {
                    park(contents)
                } else {
                    Self.logger.notice("Declined snapshot dropped; the user's newer copy owns the board")
                }
            }
        } else {
            restore(contents)
        }
    }

    /// Keeps content safe across a window in which it must not be written.
    /// The hold is the safekeeping mechanism the borrowers already use, so an
    /// existing hold wins: it is the older, truer snapshot of the user's
    /// clipboard, and both parked values are on their way back to it anyway.
    @MainActor
    private func park(_ contents: ClipboardContents) {
        guard heldUserClipboard == nil else { return }
        Self.logger.notice("Clipboard give-back parked; a selection is being read")
        heldUserClipboard = contents
    }

    /// Pasteboard types that are conventions rather than data.
    ///
    /// Clipboard-history utilities watch for these and honour them. Without
    /// them, every transcript a dictation produces is recorded into whatever
    /// history tool the user runs, which is a copy of everything they have ever
    /// said sitting in an app that made no promises about it. Marking the write
    /// transient asks for it not to be kept.
    private enum PasteboardConvention {
        /// Who put this here.
        static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")
        /// "Do not record this."
        static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        /// "This was not typed by a person."
        static let autoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        /// Our own marker, carrying an id unique to one paste. See
        /// `restoreClipboard` for why identity beats a change count.
        static let session = NSPasteboard.PasteboardType("com.micmyday.app.PasteSession")
    }

    /// The clipboard's plain text, when it holds any. Read through the
    /// injector rather than from `NSPasteboard.general` directly so a test
    /// reads its own board and never the developer's.
    var clipboardText: String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    /// Writes the transcript for a paste we intend to undo afterwards.
    ///
    /// Marked transient so clipboard managers leave it out of their history,
    /// and stamped with a one-off id so the restore can tell our own write from
    /// anything that replaced it.
    func writeForPasteForTesting(_ text: String, sessionID: String) -> Bool {
        writeForPaste(text, sessionID: sessionID)
    }

    func clipboardStillHoldsOurPasteForTesting(_ text: String, sessionID: String) -> Bool {
        clipboardStillHoldsOurPaste(text, sessionID: sessionID)
    }

    private func writeForPaste(_ text: String, sessionID: String) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if let bundle = Bundle.main.bundleIdentifier {
            pasteboard.setString(bundle, forType: PasteboardConvention.source)
        }
        pasteboard.setData(Data(), forType: PasteboardConvention.transient)
        pasteboard.setData(Data(), forType: PasteboardConvention.autoGenerated)
        return pasteboard.setString(sessionID, forType: PasteboardConvention.session)
    }

    /// Whether the clipboard still holds the exact write this paste made.
    ///
    /// Stronger than comparing change counts. A count answers "has anything
    /// happened since", which is not the same question and gets it wrong in
    /// both directions: an app that writes and restores the pasteboard bumps it
    /// twice without changing anything, and a count can also be equal by
    /// coincidence after a wrap. Matching both the text and an id written
    /// nowhere else answers the question that actually matters, which is
    /// whether the thing about to be thrown away is still ours to throw.
    fileprivate func clipboardStillHoldsOurPaste(_ text: String, sessionID: String) -> Bool {
        pasteboard.string(forType: .string) == text
            && pasteboard.string(forType: PasteboardConvention.session) == sessionID
    }

    /// Reads whatever is selected in the focused app, by copying it.
    ///
    /// The obvious way would be to ask the focused element for its selected
    /// text through the accessibility API. That is reading another app's window
    /// contents, which a sandboxed App Store app may not do, so the selection
    /// is fetched the way a person would: press Command-C and look at the
    /// clipboard. The user's own clipboard is captured first and handed back
    /// with the returned value, because this borrows it just as pasting does.
    ///
    /// Returns nil when nothing was selected. That is told apart from a failure
    /// by the change count: a copy with an empty selection leaves the clipboard
    /// untouched, so if it has not moved, there was nothing to take.
    @MainActor
    func captureSelection(
        targetPID: pid_t
    ) async -> (text: String, clipboard: ClipboardContents, changeCount: Int)? {
        guard accessibilityTrusted(), CGPreflightPostEventAccess() else { return nil }
        // A PRIVATE value-copy of the user's clipboard, never the shared hold
        // itself. When the board carries one of our own pastes, the hold's
        // CONTENT is what the user really had, so that value is copied; with
        // no hold — restore switched off — the transcript on the board is what
        // the user was told they have. Sharing the hold object was what forced
        // a loan, a token and a provenance flag into existence, and the worst
        // a value-copy can do is restore the same bytes a second time.
        let borrowed: ClipboardContents
        if pasteboard.string(forType: PasteboardConvention.session) != nil, let held = heldUserClipboard {
            borrowed = held
        } else {
            borrowed = captureClipboard()
        }
        selectionCaptureActive = true
        defer { selectionCaptureActive = false }
        let before = pasteboard.changeCount

        guard postCopyShortcut(targetPID: targetPID) else { return nil }

        // The app reads the selection and writes the clipboard on its own
        // schedule, and nothing reports when it has. Polling rather than
        // waiting a fixed time: it finishes as soon as the clipboard moves, and
        // an app that never answers costs the whole second only once.
        for _ in 0 ..< 40 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else {
            Self.logger.notice("Nothing was selected to edit")
            flushParkedRestoreIfBoardOurs()
            return nil
        }
        // Exactly one write, and one whose owner is the app we asked. More than
        // one means the user copied something in the meantime, and there is no
        // way to tell which write is which: the safe reading is that the
        // clipboard is theirs now, so their copy is left alone and no edit
        // begins on a passage that might not be what they selected.
        guard pasteboard.changeCount == before + 1 else {
            Self.logger.notice("The clipboard changed more than once while reading the selection; leaving it alone")
            return nil
        }
        // (The multi-change exit above deliberately does not flush: the board
        // belongs to whoever wrote it last, which was not us.)

        // Untrimmed. A selection that takes in its own indentation, or the
        // newline that ends its paragraph, has to come back with them: trimming
        // here and again on the way in turns an edit into a reflow, and can
        // merge two paragraphs into one.
        let selected = pasteboard.string(forType: .string) ?? ""
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            restoreClipboard(borrowed, ifUnchangedFrom: pasteboard.changeCount)
            return nil
        }
        // The count as it stands now, holding the selection we just copied.
        // Anything after this is somebody else writing to the clipboard.
        return (selected, borrowed, pasteboard.changeCount)
    }

    @discardableResult
    private func postCopyShortcut(targetPID: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        // 8 is the virtual key code for C.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Stamped as ours, so the interaction watcher that now runs across the
        // whole edit does not read this very keystroke as the user moving.
        down.setIntegerValueField(.eventSourceUserData, value: UserInteractionWatcher.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: UserInteractionWatcher.syntheticEventMarker)
        down.postToPid(targetPID)
        up.postToPid(targetPID)
        return true
    }

    /// What the clipboard held before a dictation borrowed it.
    ///
    /// Every item and every representation, not just the string: a dictation
    /// should not turn a copied image, a file, or styled text into nothing.
    /// Held as data rather than as the original items because `NSPasteboardItem`
    /// objects belong to the pasteboard and are emptied by `clearContents()`.
    struct ClipboardContents: Equatable {
        fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
        var isEmpty: Bool { items.allSatisfy(\.isEmpty) }
    }

    /// The pasteboard's current change count, for callers that need to restore
    /// whatever is there now rather than guard against a specific write.
    var currentChangeCount: Int { pasteboard.changeCount }

    func captureClipboard() -> ClipboardContents {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { stored, type in
                // Transient and private types belong to whoever wrote them and
                // are not ours to copy back.
                guard let data = item.data(forType: type) else { return }
                stored[type] = data
            }
        }
        return ClipboardContents(items: items)
    }

    /// Puts back what `captureClipboard` took, unless somebody else has written
    /// to the clipboard since.
    ///
    /// `expectedChangeCount` is what the pasteboard read after we wrote the
    /// transcript. If it has moved on, the user or another app has copied
    /// something in the meantime and that is now the thing they expect Command-V
    /// to paste; putting our snapshot back would take it away from them.
    @discardableResult
    func restoreClipboard(_ contents: ClipboardContents, ifUnchangedFrom expectedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else {
            Self.logger.notice("Clipboard not restored; something else has written to it since")
            return false
        }
        return restore(contents)
    }

    @discardableResult
    fileprivate func restore(_ contents: ClipboardContents) -> Bool {
        // Whoever returns the held snapshot ends the hold, whichever path they
        // came through — the paste restore, the edit's change-count restore, or
        // the typing path's defer. Matching by value rather than by caller is
        // what keeps one snapshot from being "given back" twice. Released only
        // when the write landed: a defer here released it on failure too, which
        // abandoned the only surviving copy of the user's clipboard.
        let matchesHold = contents == heldUserClipboard
        guard !contents.isEmpty else {
            // It was empty before, so leaving the transcript there would be
            // adding something the user never had.
            pasteboard.clearContents()
            if matchesHold { heldUserClipboard = nil }
            return true
        }
        pasteboard.clearContents()
        let restored = contents.items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.writeObjects(restored) else {
            // The clear above already happened, so the board is empty and
            // carries nothing of ours. Marked as ours again: the next borrow
            // then goes to the hold — which still has the content this write
            // failed to put back — rather than snapshotting emptiness as
            // though the user had cut everything.
            let marker = NSPasteboardItem()
            marker.setString("restore-failed", forType: PasteboardConvention.session)
            pasteboard.writeObjects([marker])
            return false
        }
        if matchesHold { heldUserClipboard = nil }
        return true
    }

    /// Sends the auto-send key after a streamed dictation, where the final
    /// text went through `insertChunk` rather than `insert`.
    ///
    /// Checks focus first: Return is destructive, and the delay before it can
    /// be long enough for the user to switch apps. Sending it blind could
    /// submit an unrelated message or run a command in a terminal.
    @discardableResult
    func postAutoSend(keyCode: CGKeyCode, flags: CGEventFlags, targetPID: pid_t?) -> Bool {
        guard
            let targetPID,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        else {
            Self.logger.notice("Auto-send skipped; the target app is no longer frontmost")
            return false
        }
        return postKeyStroke(keyCode: keyCode, flags: flags)
    }

    private func focusApplication(processIdentifier: pid_t) async -> Bool {
        guard
            let application = NSRunningApplication(processIdentifier: processIdentifier),
            !application.isTerminated
        else { return false }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier {
            guard application.activate(options: [.activateAllWindows]) else { return false }
            for _ in 0 ..< 20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
                    break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        // Being frontmost is not the same as having a key window ready for a
        // keystroke; posting immediately raced the app and the paste was
        // silently dropped.
        try? await Task.sleep(nanoseconds: 80_000_000)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    @discardableResult
    private func postKeyStroke(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = flags
        keyUp.flags = flags
        Self.markAsSynthetic(keyDown, keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Stamps events as MicMyDay's own, so watching for user input does not
    /// mistake our typing for the user interrupting it.
    private static func markAsSynthetic(_ events: CGEvent...) {
        for event in events {
            event.setIntegerValueField(
                .eventSourceUserData,
                value: UserInteractionWatcher.syntheticEventMarker
            )
        }
    }

    private func postPasteShortcut() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        Self.markAsSynthetic(keyDown, keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
