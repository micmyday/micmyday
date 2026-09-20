import XCTest
@testable import MicMyDay

final class RewriteTransportTests: XCTestCase {
    func testCustomHeadersAndTokenReachConfiguredEndpointAfterConsent() async throws {
        let consent = expectation(description: "Consent requested")
        let requestSent = expectation(description: "Request sent")
        RewriteTestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://server.example/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "custom-value")
            requestSent.fulfill()
            return Data(#"{"choices":[{"message":{"role":"assistant","content":"  Clean transcript.  "}}]}"#.utf8)
        }
        defer { RewriteTestURLProtocol.handler = nil }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let enhancer = TranscriptEnhancer(session: session) { request in
            XCTAssertEqual(request.recipient, "https://server.example/v1")
            XCTAssertEqual(request.content, .transcript)
            consent.fulfill()
        }
        let result = try await enhancer.enhance("Raw transcript.", configuration: configuration())
        XCTAssertEqual(result, "Clean transcript.")
        await fulfillment(of: [consent, requestSent], timeout: 1, enforceOrder: true)
    }

    func testDecliningConsentPreventsNetworkRequest() async throws {
        RewriteTestURLProtocol.handler = { _ in
            XCTFail("Cancelled sharing must not send a request")
            return Data()
        }
        defer { RewriteTestURLProtocol.handler = nil }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let enhancer = TranscriptEnhancer(session: session) { _ in throw DataSharingError.declined }
        do {
            _ = try await enhancer.enhance("Private transcript.", configuration: configuration())
            XCTFail("Expected sharing cancellation")
        } catch {
            XCTAssertTrue(error is DataSharingError)
        }
    }

    private func configuration() -> EnhancementConfiguration {
        EnhancementConfiguration(
            baseURL: "https://server.example/v1", model: "test-model", apiKey: "test-token",
            systemPrompt: "Clean up dictation.", customHeaders: [
                CustomHeader(name: "Authorization", value: ""),
                CustomHeader(name: "X-Test", value: "custom-value")
            ]
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RewriteTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RewriteTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
