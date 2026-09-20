import XCTest
@testable import MicMyDay

/// These go through a real URLSession and the real byte stream, which is the
/// only way to catch framing bugs: parsing the SSE text directly in a test
/// hides them, because the bug was in how the bytes became lines at all.
final class StreamingTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StreamTestURLProtocol.bodies = []
        StreamTestURLProtocol.status = 200
        StreamTestURLProtocol.requestCount = 0
        StreamTestURLProtocol.contentType = "text/event-stream"
        StreamTestURLProtocol.gate = nil
        StreamTestURLProtocol.firstPart = nil
    }

    private func makeTranscriber() -> OpenAICompatibleTranscriber {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamTestURLProtocol.self]
        return OpenAICompatibleTranscriber(session: URLSession(configuration: configuration))
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString).wav")
        try Data(repeating: 0x41, count: 32).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func configuration(model: String = "gpt-transcribe") -> TranscriptionConfiguration {
        TranscriptionConfiguration(
            provider: .openAI,
            baseURL: "https://example.test/v1",
            model: model,
            apiKey: "test-key",
            language: "",
            prompt: "",
            preferOnDevice: false
        )
    }

    private func transcribe(
        _ body: String,
        model: String = "gpt-transcribe",
        contentType: String = "text/event-stream"
    ) async throws -> (text: String, deltas: [String], requests: Int) {
        StreamTestURLProtocol.bodies = [body]
        StreamTestURLProtocol.contentType = contentType
        let deltas = Deltas()
        let text = try await makeTranscriber().transcribeStreaming(
            fileURL: try audioFile(),
            configuration: configuration(model: model),
            onDelta: { delta in deltas.append(delta) }
        )
        return (text, deltas.all, StreamTestURLProtocol.requestCount)
    }

    func testAnOrdinaryOpenAIStreamDeliversItsDeltas() async throws {
        let body = """
        data: {"type":"transcript.text.delta","delta":"Hello "}

        data: {"type":"transcript.text.delta","delta":"world"}

        data: {"type":"transcript.text.done","text":"Hello world"}

        data: [DONE]

        """
        let result = try await transcribe(body)
        XCTAssertEqual(result.deltas, ["Hello ", "world"], "Deltas must reach the caller as they arrive")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.requests, 1, "A working stream must not also fall back")
    }

    func testDeltasArriveWhileTheResponseIsStillOpen() async throws {
        // The point of streaming is that words appear before the request ends.
        // Asserting on the deltas after the call returns cannot tell the
        // difference between that and delivering everything at the very end,
        // so the rest of the stream is withheld until a delta has been seen.
        let gate = DispatchSemaphore(value: 0)
        StreamTestURLProtocol.gate = gate
        StreamTestURLProtocol.firstPart =
            "data: {\"type\":\"transcript.text.delta\",\"delta\":\"early \"}\n\n"
        StreamTestURLProtocol.bodies = [
            "data: {\"type\":\"transcript.text.delta\",\"delta\":\"late\"}\n\n"
                + "data: {\"type\":\"transcript.text.done\",\"text\":\"early late\"}\n\n"
        ]

        let deltas = Deltas()
        let sawEarly = expectation(description: "a delta arrived before the response finished")
        let transcriber = makeTranscriber()
        let file = try audioFile()
        let configuration = configuration()

        let work = Task {
            try await transcriber.transcribeStreaming(
                fileURL: file,
                configuration: configuration,
                onDelta: { delta in
                    deltas.append(delta)
                    if delta == "early " { sawEarly.fulfill() }
                }
            )
        }

        // If this times out, nothing was delivered progressively: the stub is
        // still holding the rest of the stream.
        await fulfillment(of: [sawEarly], timeout: 5)
        gate.signal()

        let text = try await work.value
        XCTAssertEqual(deltas.all, ["early ", "late"])
        XCTAssertEqual(text, "early late")
    }

    func testCarriageReturnLineEndingsWorkToo() async throws {
        let body = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hi\"}\r\n\r\n"
            + "data: {\"type\":\"transcript.text.done\",\"text\":\"Hi\"}\r\n\r\n"
        let result = try await transcribe(body)
        XCTAssertEqual(result.deltas, ["Hi"])
        XCTAssertEqual(result.text, "Hi")
    }

    func testAlternateEventNamesAreUnderstood() async throws {
        // Some servers name these events differently and put the delta in `text`.
        let body = """
        data: {"type":"transcription.text.delta","text":"Bonjour "}

        data: {"type":"transcription.text.delta","text":"le monde"}

        data: {"type":"transcription.done","text":"Bonjour le monde"}

        """
        let result = try await transcribe(body)
        XCTAssertEqual(result.deltas, ["Bonjour ", "le monde"])
        XCTAssertEqual(result.text, "Bonjour le monde")
    }

    func testALeadingByteOrderMarkDoesNotEatTheFirstWords() async throws {
        // The done event deliberately carries different text: asserting on the
        // final transcript alone would pass even if the BOM swallowed the first
        // delta, because the done event would supply the expected words.
        let body = "\u{FEFF}data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hello world\"}\n\n"
            + "data: {\"type\":\"transcript.text.done\",\"text\":\"ignored\"}\n\n"
        let result = try await transcribe(body)
        XCTAssertEqual(
            result.deltas, ["Hello world"],
            "A byte-order mark must not stop the first field from being read"
        )
    }

    func testATruncatedStreamIsAnErrorRatherThanAHalfTranscript() async {
        // Deltas but no completion event: returning the partial text would let
        // auto-send submit half a sentence.
        let body = """
        data: {"type":"transcript.text.delta","delta":"Half a sen"}

        """
        do {
            _ = try await transcribe(body)
            XCTFail("A truncated stream must not be reported as a finished transcript")
        } catch {}
    }

    func testAnErrorEventCarryingABareStringIsSurfaced() async {
        // Terminated properly, so the only thing that can fail this run is the
        // error event itself. Without that handling the stream would end
        // cleanly and "Some words" would be returned as a transcript.
        let body = """
        data: {"type":"transcript.text.delta","delta":"Some words"}

        event: error
        data: overloaded

        data: [DONE]

        """
        do {
            let result = try await transcribe(body)
            XCTFail("An error event must not pass as a transcript, got \(result.text)")
        } catch let error as TranscriptionError {
            // The provider's own wording has to reach the user, not a generic
            // failure: "overloaded" tells them to retry.
            guard case .server(_, let message) = error else {
                return XCTFail("Expected a server error, got \(error)")
            }
            XCTAssertTrue(
                message.contains("overloaded"),
                "The provider's message must be surfaced, got: \(message)"
            )
        } catch {
            XCTFail("Expected a TranscriptionError, got \(error)")
        }
    }

    func testAStreamOfOnlyKeepAlivesIsNotATranscript() async {
        // The comment bytes must never come back as text: they would be pasted
        // and, with auto-send on, submitted.
        do {
            let result = try await transcribe(": keep-alive\n\n")
            XCTFail("Protocol noise must not become a transcript, got \(result.text)")
        } catch {}
    }

    func testACombiningMarkSplitAcrossDeltasIsNotLost() async throws {
        // "Cafe" then a combining acute: the accent extends the previous
        // grapheme, so reconstructing deltas by character count drops it.
        let body = """
        data: {"type":"transcript.text.delta","delta":"Cafe"}

        data: {"type":"transcript.text.delta","delta":"\u{0301} noir"}

        data: {"type":"transcript.text.done","text":"Caf\u{0301} noir"}

        """
        let result = try await transcribe(body)
        XCTAssertEqual(result.deltas, ["Cafe", "\u{0301} noir"], "Deltas must arrive exactly as sent")
    }

    func testAProviderThatIgnoredStreamingIsUsedRatherThanRetried() async throws {
        // An ordinary JSON body on 200. Re-uploading would bill the user twice.
        let result = try await transcribe(
            #"{"text":"Plain response"}"#,
            contentType: "application/json"
        )
        XCTAssertEqual(result.text, "Plain response")
        XCTAssertEqual(result.requests, 1)
    }

    func testAPlainTextBodyIsAlsoUsedRatherThanRetried() async throws {
        let result = try await transcribe("Just the words", contentType: "text/plain")
        XCTAssertEqual(result.text, "Just the words")
        XCTAssertEqual(result.requests, 1)
    }

    func testWhisperSkipsStreamingEntirelyAndStillTranscribes() async throws {
        let result = try await transcribe(
            #"{"text":"From whisper"}"#,
            model: "whisper-1",
            contentType: "application/json"
        )
        XCTAssertEqual(result.text, "From whisper")
        XCTAssertEqual(result.requests, 1, "Asking a model known not to stream wastes a request")
    }

    func testAServerFaultIsNotRetried() async {
        StreamTestURLProtocol.status = 500
        StreamTestURLProtocol.bodies = [#"{"error":{"message":"boom"}}"#]
        do {
            _ = try await makeTranscriber().transcribeStreaming(
                fileURL: try audioFile(),
                configuration: configuration(),
                onDelta: { _ in }
            )
            XCTFail("A server fault must surface, not be retried")
        } catch {
            XCTAssertEqual(
                StreamTestURLProtocol.requestCount, 1,
                "Retrying a 500 can bill the user for a second transcription"
            )
        }
    }
}

/// Collects deltas from the main actor without tripping concurrency checking.
private final class Deltas: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class StreamTestURLProtocol: URLProtocol {
    static var bodies: [String] = []
    static var status = 200
    static var requestCount = 0
    static var contentType = "text/event-stream"
    /// When set, the stub sends the first element, then waits for this to be
    /// signalled before sending the rest.
    static var gate: DispatchSemaphore?
    static var firstPart: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.requestCount
        Self.requestCount += 1
        let body = index < Self.bodies.count ? Self.bodies[index] : (Self.bodies.last ?? "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let gate = Self.gate, let firstPart = Self.firstPart {
            // Hold the rest back so the test can prove a delta was delivered
            // while the response was still open.
            client?.urlProtocol(self, didLoad: Data(firstPart.utf8))
            gate.wait()
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
