import XCTest
@testable import MicMyDay

final class DataSharingConsentTests: XCTestCase {
    @MainActor
    func testApprovalIsScopedToDestinationAndContentAndCanBeReset() throws {
        let suite = "DataSharingConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompts = 0
        let consent = DataSharingConsent(defaults: defaults) { _ in prompts += 1; return true }
        let audio = try DataSharingRequest.provider("https://example.com/v1/", content: .audio)
        try consent.requirePermission(for: audio)
        try consent.requirePermission(for: .provider("https://EXAMPLE.com/v1", content: .audio))
        XCTAssertEqual(prompts, 1)
        try consent.requirePermission(for: .provider("https://example.com/v1", content: .transcript))
        try consent.requirePermission(for: .provider("https://another.example/v1", content: .audio))
        XCTAssertEqual(prompts, 3)
        consent.reset()
        try consent.requirePermission(for: audio)
        XCTAssertEqual(prompts, 4)
    }

    @MainActor
    func testCancellationNeverRecordsApproval() throws {
        let suite = "DataSharingConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var prompts = 0
        let consent = DataSharingConsent(defaults: defaults) { _ in prompts += 1; return false }
        let request = try DataSharingRequest.provider("https://example.com", content: .audio)
        XCTAssertThrowsError(try consent.requirePermission(for: request))
        XCTAssertThrowsError(try consent.requirePermission(for: request))
        XCTAssertEqual(prompts, 2)
    }

    func testLocalSpeechDoesNotAskToShareAudio() throws {
        func configuration(_ provider: TranscriptionProviderKind, onDevice: Bool) -> TranscriptionConfiguration {
            TranscriptionConfiguration(provider: provider, baseURL: "", model: "", apiKey: "", language: "", prompt: "", preferOnDevice: onDevice)
        }
        XCTAssertNil(try DataSharingRequest.transcription(configuration(.whisper, onDevice: false)))
        XCTAssertNil(try DataSharingRequest.transcription(configuration(.appleSpeech, onDevice: true)))
        XCTAssertEqual(try DataSharingRequest.transcription(configuration(.appleSpeech, onDevice: false))?.recipient, "Apple Speech")
    }
}
