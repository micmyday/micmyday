import XCTest
@testable import MicMyDay

final class ProviderNetworkingTests: XCTestCase {
    func testAllowsHTTPSAndLocalHTTPProviders() throws {
        for address in [
            "https://api.example.com/v1", "http://localhost:11434/v1",
            "http://127.0.0.1:8000/v1", "http://192.168.1.20:11434/v1",
            "http://10.0.0.5:8000/v1", "http://172.16.0.1:8000/v1",
            "http://inference.local:8000/v1", "http://homeserver:8000/v1",
            "http://[::1]:11434/v1", "http://[fd12::1]:8000/v1"
        ] {
            XCTAssertNoThrow(try ProviderNetworking.validatedComponents(for: address), address)
        }
    }

    func testRejectsUnprotectedInternetEndpointsAndEmbeddedCredentials() {
        for address in [
            "http://api.example.com/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1",
            "https://user:secret@example.com/v1", "https://example.com/v1?key=secret",
            "https://example.com/v1#fragment", "ftp://localhost/model", "https:///v1"
        ] {
            XCTAssertThrowsError(try ProviderNetworking.validatedComponents(for: address), address)
        }
    }
}
