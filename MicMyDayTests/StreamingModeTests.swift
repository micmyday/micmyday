import XCTest
@testable import MicMyDay

/// Direct paste writes into someone else's document, so the rules about when it
/// is offered and how much it releases are the part worth pinning down.
final class StreamingModeTests: XCTestCase {
    func testOnlyDirectPasteTouchesTheTargetAppEarly() {
        XCTAssertFalse(StreamingMode.off.writesPartialTextToTargetApp)
        XCTAssertFalse(StreamingMode.overlay.writesPartialTextToTargetApp)
        XCTAssertTrue(StreamingMode.directPaste.writesPartialTextToTargetApp)
    }

    func testOnlyEnginesWithAStreamingAPIOfferTheSetting() {
        for provider in [TranscriptionProviderKind.openAI, .custom] {
            XCTAssertTrue(
                provider.supportsStreamingTranscription,
                "\(provider) speaks the OpenAI transcription API, which has stream=true"
            )
        }
        // Apple's recogniser is the only one that takes a live audio stream, so
        // it is the only engine where the words appear while the user is still
        // speaking rather than after they stop. It has to offer the setting, or
        // the feature has no control that turns it on.
        XCTAssertTrue(TranscriptionProviderKind.appleSpeech.supportsStreamingTranscription)

        for provider in [TranscriptionProviderKind.whisper, .gemini] {
            XCTAssertFalse(
                provider.supportsStreamingTranscription,
                "\(provider) only returns a finished transcript"
            )
        }
    }

    @MainActor
    func testAnEngineThatCannotStreamFallsBackToOffWhateverIsStored() {
        let name = "StreamingModeTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "StreamingModeTests.\(UUID().uuidString)")
        )

        XCTAssertEqual(settings.streamingMode, .off, "Pasting as you go is opt-in")

        settings.streamingMode = .directPaste
        settings.provider = .openAI
        XCTAssertEqual(settings.effectiveStreamingMode, .directPaste)

        // Switching to a local engine must not keep claiming to stream.
        settings.provider = .whisper
        XCTAssertEqual(settings.effectiveStreamingMode, .off)

        // ...and the stored choice survives, so switching back restores it.
        settings.provider = .openAI
        XCTAssertEqual(settings.effectiveStreamingMode, .directPaste)
    }
}

/// The buffer decides what reaches the user's document, so a mistake here shows
/// up as a word split in half in someone's email.
final class StreamingPasteBufferTests: XCTestCase {
    func testNothingIsReleasedUntilThereIsEnoughToBeWorthAPaste() {
        var buffer = StreamingPasteBuffer()
        XCTAssertNil(buffer.append("Hello "))
        XCTAssertNil(buffer.append("there "))
    }

    func testReleasesOnlyUpToTheLastSpaceSoWordsAreNeverSplit() {
        var buffer = StreamingPasteBuffer()
        // Long enough to cross the threshold, and ending mid-word: "jumpi"
        // could still grow into "jumping", so only settled words come out.
        let released = buffer.append("The quick brown fox jumpi")
        XCTAssertEqual(released, "The quick brown fox ")

        // The held-back fragment is still there and completes normally.
        _ = buffer.append("ng over the lazy dog now")
        XCTAssertEqual(buffer.drain(), "now")
    }

    func testAnUnbrokenRunOfCharactersIsHeldRatherThanSplit() {
        var buffer = StreamingPasteBuffer()
        // A long token with no space in it: splitting it would be worse than
        // waiting, so nothing comes out.
        XCTAssertNil(buffer.append(String(repeating: "x", count: 80)))
    }

    func testDrainReturnsTheRemainderExactlyOnce() {
        var buffer = StreamingPasteBuffer()
        _ = buffer.append("some settled words here ")
        _ = buffer.append("tail")
        XCTAssertEqual(buffer.drain(), "tail")
        XCTAssertNil(buffer.drain(), "Draining twice must not paste the tail twice")
    }

    func testEveryCharacterComesOutOnceAndInOrder() {
        let source = "One morning I woke up and decided to write this down properly."
        var buffer = StreamingPasteBuffer()
        var rebuilt = ""
        // Feed it in small pieces, the way a provider emits deltas.
        for chunk in source.chunked(into: 3) {
            if let released = buffer.append(chunk) { rebuilt += released }
        }
        rebuilt += buffer.drain() ?? ""
        XCTAssertEqual(rebuilt, source, "Streaming must lose and duplicate nothing")
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var pieces: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            pieces.append(String(self[index ..< end]))
            index = end
        }
        return pieces
    }
}

/// Direct paste hands words to someone else's document, where a mistake cannot
/// be taken back. Order and never-paste-twice are the two guarantees.
@MainActor
final class StreamingSessionTests: XCTestCase {
    func testChunksReachTheAppInOrderEvenWhenDeliveryIsSlowAndUneven() async {
        let session = StreamingSession()
        var delivered: [String] = []
        // Deliberately make the first chunk the slowest: with one task per
        // chunk the later ones would overtake it.
        let delays: [String: UInt64] = ["one ": 40, "two ": 20, "three ": 5]
        for chunk in ["one ", "two ", "three "] {
            session.enqueue(chunk) { piece in
                try? await Task.sleep(nanoseconds: (delays[piece] ?? 0) * 1_000_000)
                delivered.append(piece)
                return piece
            }
        }
        await session.drainQueue()
        XCTAssertEqual(delivered, ["one ", "two ", "three "])
    }

    func testAChunkThatDidNotLandStopsTheRestRatherThanScatteringThem() async {
        let session = StreamingSession()
        var delivered: [String] = []
        session.enqueue("first ") { _ in "" }
        session.enqueue("second ") { piece in
            delivered.append(piece)
            return piece
        }
        await session.drainQueue()
        XCTAssertTrue(session.stopped)
        XCTAssertEqual(delivered, [], "Nothing may follow a chunk that never landed")
        XCTAssertEqual(session.pasted, "", "Undelivered words must not count as delivered")
    }

    func testOnlyThePartThatActuallyLandedCountsAsDelivered() async {
        let session = StreamingSession()
        // The app took half the chunk before the user clicked elsewhere.
        session.enqueue("Hello world") { piece in String(piece.prefix(6)) }
        await session.drainQueue()
        XCTAssertEqual(session.pasted, "Hello ")
        XCTAssertTrue(session.stopped)
        // The rest is handed over exactly, with nothing repeated or skipped.
        XCTAssertEqual(session.undelivered(of: "Hello world"), "world")
    }

    func testOnlyTheUndeliveredTailIsLeftToPaste() async {
        let session = StreamingSession()
        session.enqueue("Hello there ") { piece in piece }
        // Delivery is asynchronous, and words only count once they have landed.
        await session.drainQueue()
        // The finished transcript repeats what was typed, so only the rest of
        // it may be added; sending all of it would duplicate the opening.
        XCTAssertEqual(session.undelivered(of: "Hello there world"), "world")
    }

    func testNothingPastedYetMeansTheWholeTranscriptIsStillOwed() {
        let session = StreamingSession()
        XCTAssertEqual(session.undelivered(of: "Hello world"), "Hello world")
    }

    func testDivergedTextIsRefusedRatherThanAppended() async {
        let session = StreamingSession()
        session.enqueue("Hello there ") { piece in piece }
        await session.drainQueue()
        // A retry worded differently: appending would corrupt the document, so
        // the caller is told to fall back to the clipboard.
        XCTAssertNil(session.undelivered(of: "Hi there world"))
    }
}

/// The wire format decides whether a transcript survives. Two providers use
/// different event names, and a truncated stream must never look finished.
final class StreamingSSETests: XCTestCase {
    private typealias Parser = OpenAICompatibleTranscriber.SSEParser

    private func events(_ lines: [String]) -> [Parser.Event] {
        var parser = Parser()
        var out: [Parser.Event] = []
        for line in lines {
            if let event = parser.consume(line) { out.append(event) }
        }
        if let last = parser.flush() { out.append(last) }
        return out
    }

    func testOneEventPerBlankLineSeparatedBlock() {
        let parsed = events(["data: {\"a\":1}", "", "data: {\"b\":2}", ""])
        XCTAssertEqual(parsed.map(\.data), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testDataSplitAcrossLinesIsJoinedRatherThanDropped() {
        // The spec joins multiple data fields with a newline. Decoding each
        // line separately would fail on both halves and lose the event.
        let parsed = events(["data: {\"type\":", "data: \"x\"}", ""])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].data, "{\"type\":\n\"x\"}")
    }

    func testTheEventNameIsKeptForEnvelopesThatCarryNoType() {
        let parsed = events(["event: error", "data: {\"error\":{\"message\":\"nope\"}}", ""])
        XCTAssertEqual(parsed.first?.name, "error")
    }

    func testCommentsAndKeepAlivesAreIgnored() {
        XCTAssertTrue(events([": keep-alive", ""]).isEmpty)
    }

    func testAStreamEndingWithoutABlankLineStillYieldsItsLastEvent() {
        let parsed = events(["data: [DONE]"])
        XCTAssertEqual(parsed.map(\.data), ["[DONE]"])
    }

    func testOnlyLeadingSpaceIsStrippedSoTextKeepsItsSpacing() {
        // "data:  two spaces" must keep the second one: transcripts are made of
        // words and the spaces between them.
        XCTAssertEqual(events(["data:  x", ""]).first?.data, " x")
    }

    func testModelsKnownNotToStreamAreNotAsked() {
        XCTAssertFalse(OpenAICompatibleTranscriber.modelCanStream("whisper-1"))
        XCTAssertTrue(OpenAICompatibleTranscriber.modelCanStream("gpt-transcribe"))
        XCTAssertTrue(OpenAICompatibleTranscriber.modelCanStream("gpt-4o-transcribe"))
    }
}

/// Typed characters go straight into the user's document, so batching must not
/// break them apart.
final class UnicodeTypingTests: XCTestCase {
    func testPlainTextIsSplitIntoBatchesWithinTheLimit() {
        let batches = TextInjector.unicodeBatches(of: String(repeating: "a", count: 40), limit: 16)
        XCTAssertEqual(batches.joined(), String(repeating: "a", count: 40))
        XCTAssertTrue(batches.allSatisfy { $0.utf16.count <= 16 })
    }

    func testASurrogatePairIsNeverSplitAcrossTwoEvents() {
        // An emoji is two UTF-16 units; splitting it would post two broken
        // halves and the user would see replacement characters.
        let text = String(repeating: "👍", count: 10)
        let batches = TextInjector.unicodeBatches(of: text, limit: 5)
        for batch in batches {
            XCTAssertEqual(batch.utf16.count % 2, 0, "Batches must break between characters")
        }
        XCTAssertEqual(batches.joined(), text)
    }

    func testANewlineGetsItsOwnEventSoTheTextAfterItSurvives() {
        // AppKit reads a batch that starts with a control character as an
        // editing command and throws away the rest of that batch, so a newline
        // must never lead or share a batch.
        let rendered = TextInjector.unicodeBatches(of: "abcdefghijklmnop\nsecond", limit: 16)
        XCTAssertEqual(rendered.joined(), "abcdefghijklmnop\nsecond")
        XCTAssertTrue(rendered.contains("\n"), "The newline stands alone")
        XCTAssertFalse(
            rendered.contains { $0.count > 1 && ($0.first == "\n" || $0.first == "\t") },
            "No batch may begin with a control character and carry text behind it"
        )
    }

    func testATabIsIsolatedTheSameWay() {
        XCTAssertEqual(TextInjector.unicodeBatches(of: "\tsecond", limit: 16), ["\t", "second"])
    }

    func testEveryCharacterSurvivesBatching() {
        let text = "Grüße, café — naïve façade 🎉 done."
        XCTAssertEqual(TextInjector.unicodeBatches(of: text, limit: 7).joined(), text)
    }
}

/// Cancellation and the tab fallback are where the last review rounds kept
/// finding text going astray, so the rules are pinned here.
@MainActor
final class StreamingCancellationTests: XCTestCase {
    func testCancellingStopsFurtherChunksFromBeingQueued() async {
        let session = StreamingSession()
        var delivered: [String] = []
        session.enqueue("first ") { piece in delivered.append(piece); return piece }
        session.cancelled = true
        session.enqueue("second ") { piece in delivered.append(piece); return piece }
        await session.drainQueue()
        XCTAssertFalse(delivered.contains("second "), "Nothing may be queued after Escape")
    }

    func testStoppingHaltsTypingButKeepsTheRestRecoverable() async {
        let session = StreamingSession()
        session.enqueue("Hello ") { piece in piece }
        await session.drainQueue()
        session.stopStreaming()
        // Stopping must halt delivery outright. It is set when the user clicks
        // somewhere, and at that point nothing more may be typed, because the
        // destination is no longer known to be the one they dictated into.
        XCTAssertFalse(session.acceptsMoreChunks)
        XCTAssertFalse(session.shouldContinue)
        XCTAssertFalse(session.failed, "But it is a clean stop, not a failure")
        // What was typed is still an exact prefix, so the rest can be handed
        // over accurately rather than re-sending the whole transcript.
        XCTAssertEqual(session.undelivered(of: "Hello world"), "world")
    }

    func testStoppingPreventsAnythingQueuedBehindItFromBeingTyped() async {
        let session = StreamingSession()
        let delivered = Recorder()
        session.stopStreaming()
        session.enqueue("never ") { piece in delivered.append(piece); return piece }
        await session.drainQueue()
        XCTAssertTrue(
            delivered.all.isEmpty,
            "A stop must stop delivery, not just stop new words being buffered"
        )
    }

    func testControlCharactersAreRefusedForTyping() {
        // A tab moves focus to the next field, so everything after it would
        // land somewhere else entirely.
        XCTAssertTrue(StreamingSession.mustNotBeTyped("before\tafter"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("line one\nline two"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("one\r\ntwo"))
        // Delete and backspace remove text the user already had, rather than
        // adding any: typing them destroys the words in front of them.
        XCTAssertTrue(StreamingSession.mustNotBeTyped("before\u{7F}after"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("before\u{08}after"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("bell\u{07}"))
        // AppKit maps its function keys onto a private-use block, so these are
        // read as Delete or an arrow key rather than as characters.
        XCTAssertTrue(StreamingSession.mustNotBeTyped("before\u{F728}after"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("before\u{F702}after"))
        XCTAssertTrue(StreamingSession.mustNotBeTyped("\u{F700}"))

        // Ordinary dictation, including accents and emoji, is unaffected.
        XCTAssertFalse(StreamingSession.mustNotBeTyped("ordinary words, punctuation!"))
        XCTAssertFalse(StreamingSession.mustNotBeTyped("Grüße, café 🎉"))
        // Ordinary dictation must never be diverted to the clipboard path.
        XCTAssertFalse(StreamingSession.mustNotBeTyped("A sentence — with punctuation: \"quoted\"!"))
        XCTAssertFalse(StreamingSession.mustNotBeTyped("family 👨‍👩‍👧‍👦 and flag 🇩🇪"))
        XCTAssertFalse(StreamingSession.mustNotBeTyped("日本語のテキスト"))
    }

    func testCancellingWhileAChunkIsInFlightStopsTheOnesBehindIt() async {
        let session = StreamingSession()
        let delivered = Recorder()
        let firstStarted = expectation(description: "first chunk started")

        // Delivery has to actually suspend, the way a real paste does while it
        // waits for focus. A fake that returns immediately leaves no window for
        // cancellation, so the guards it is meant to exercise are never reached
        // and the test passes even with all of them removed.
        session.enqueue("one ") { piece in
            firstStarted.fulfill()
            try? await Task.sleep(nanoseconds: 80_000_000)
            delivered.append(piece)
            return piece
        }
        session.enqueue("two ") { piece in
            delivered.append(piece)
            return piece
        }

        await fulfillment(of: [firstStarted], timeout: 2)
        session.cancelled = true
        await session.drainQueue()

        XCTAssertEqual(
            delivered.all, ["one "],
            "The chunk already in flight completes; nothing queued behind it may be typed"
        )
    }

    func testCancellingBeforeDeliveryStopsEverything() async {
        let session = StreamingSession()
        let delivered = Recorder()
        session.cancelled = true
        session.enqueue("never ") { piece in
            delivered.append(piece)
            return piece
        }
        await session.drainQueue()
        XCTAssertTrue(delivered.all.isEmpty)
    }
}

/// Collects delivery order across suspension points.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Pasting straight into whatever you were writing is the point of the app, so
/// it is on unless the user turns it off.
final class AutomaticPasteDefaultTests: XCTestCase {
    @MainActor
    func testPastingIsOnByDefaultAndCanBeTurnedOff() {
        let name = "AutomaticPasteDefaultTests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "\(name).\(UUID().uuidString)")
        )
        XCTAssertTrue(settings.automaticPasteEnabled, "Dictating into the focused app is the default")

        settings.automaticPasteEnabled = false
        XCTAssertFalse(settings.automaticPasteEnabled)
    }

    func testAccessibilityIsOnlyRequiredWhenPastingIsOn() {
        // The permission exists solely to paste, so it must not be reported as
        // missing while the feature that needs it is off.
        XCTAssertEqual(
            PermissionIssue.missing(
                microphone: true, speech: true, accessibility: false, inputMonitoring: true,
                provider: .whisper, modifierOnlyShortcut: false, automaticPaste: false
            ),
            []
        )
        XCTAssertEqual(
            PermissionIssue.missing(
                microphone: true, speech: true, accessibility: false, inputMonitoring: true,
                provider: .whisper, modifierOnlyShortcut: false, automaticPaste: true
            ),
            [.accessibility]
        )
    }
}
