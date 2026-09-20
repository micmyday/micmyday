import XCTest
@testable import MicMyDay

final class OpenAICompatibleTranscriberTests: XCTestCase {
    func testBuildsEndpointFromVersionedBaseURL() throws {
        let endpoint = try OpenAICompatibleTranscriber.transcriptionEndpoint(
            for: "http://127.0.0.1:8000/v1/"
        )
        XCTAssertEqual(endpoint.absoluteString, "http://127.0.0.1:8000/v1/audio/transcriptions")
    }

    func testKeepsCompleteTranscriptionEndpoint() throws {
        let endpoint = try OpenAICompatibleTranscriber.transcriptionEndpoint(
            for: "https://example.test/v1/audio/transcriptions"
        )
        XCTAssertEqual(endpoint.absoluteString, "https://example.test/v1/audio/transcriptions")
    }

    func testRejectsUnsupportedURLScheme() {
        XCTAssertThrowsError(
            try OpenAICompatibleTranscriber.transcriptionEndpoint(for: "file:///tmp/v1")
        )
    }
}

