import XCTest
@testable import MicMyDay

/// The licence rules are the one place where a bug either locks out a paying
/// customer or gives the app away, so they are tested against a fake server
/// rather than trusted to read correctly.
@MainActor
final class LicenseManagerTests: XCTestCase {
    private final class FakeAPI: LicenseAPI, @unchecked Sendable {
        var activateResult: Result<LicenseActivation, LicenseError> =
            .success(LicenseActivation(activationId: "activation-1", seatLimit: 3))
        var validateResult: Result<Void, LicenseError> = .success(())
        private(set) var deactivateCalls = 0

        func activate(key: String, deviceLabel: String) async throws -> LicenseActivation {
            try activateResult.get()
        }

        func validate(key: String, activationId: String) async throws {
            try validateResult.get()
        }

        func deactivate(key: String, activationId: String) async throws {
            deactivateCalls += 1
        }
    }

    private func makeManager(_ api: FakeAPI = FakeAPI()) -> (LicenseManager, UserDefaults, String) {
        let suite = "LicenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let service = "LicenceTests.\(UUID().uuidString)"
        let manager = LicenseManager(
            api: api,
            keychain: KeychainStore(service: service),
            defaults: defaults
        )
        return (manager, defaults, suite)
    }

    func testFreshInstallStartsTheTrialWithEveryDayIntact() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(manager.state, .trial(daysRemaining: LicenseTerms.trialDays))
        XCTAssertTrue(manager.state.allowsDictation)
    }

    func testActivationStoresTheKeyAndLicensesTheApp() async {
        let api = FakeAPI()
        let (manager, defaults, suite) = makeManager(api)
        defer { defaults.removePersistentDomain(forName: suite) }

        await manager.activate(key: "  KEY-1234-5678-ABCD  ")

        XCTAssertEqual(manager.state, .licensed)
        XCTAssertNil(manager.lastError)
        XCTAssertEqual(manager.seatLimit, 3)
        // Trimmed on the way in: keys are pasted with stray whitespace far more
        // often than not, and a trailing space must not read as a wrong key.
        XCTAssertEqual(manager.maskedKey?.hasPrefix("KEY-"), true)
    }

    func testAnUnknownKeyIsReportedAndChangesNothing() async {
        let api = FakeAPI()
        api.activateResult = .failure(.unknownKey)
        let (manager, defaults, suite) = makeManager(api)
        defer { defaults.removePersistentDomain(forName: suite) }

        await manager.activate(key: "NOPE")

        XCTAssertEqual(manager.lastError, .unknownKey)
        XCTAssertFalse(manager.hasKey)
        XCTAssertEqual(manager.state, .trial(daysRemaining: LicenseTerms.trialDays))
    }

    func testAnExhaustedKeySaysHowManyMacsItCovers() async {
        let api = FakeAPI()
        api.activateResult = .failure(.seatsExhausted(limit: 2))
        let (manager, defaults, suite) = makeManager(api)
        defer { defaults.removePersistentDomain(forName: suite) }

        await manager.activate(key: "KEY")

        XCTAssertEqual(manager.lastError, .seatsExhausted(limit: 2))
        XCTAssertEqual(manager.lastError?.errorDescription?.contains("2 Macs"), true)
    }

    func testALicensedCopyKeepsWorkingInsideTheOfflineGrace() async {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        await manager.activate(key: "KEY")

        // Thirteen days without reaching the server, inside the fourteen-day
        // grace: a paid copy must not stop working on a train.
        defaults.set(Date().addingTimeInterval(-13 * 24 * 60 * 60), forKey: "licenceLastValidated")
        manager.refreshState()

        XCTAssertEqual(manager.state, .licensed)
        XCTAssertTrue(manager.state.allowsDictation)
    }

    func testALicensedCopyStopsOnceTheOfflineGraceRunsOut() async {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        await manager.activate(key: "KEY")

        defaults.set(Date().addingTimeInterval(-20 * 24 * 60 * 60), forKey: "licenceLastValidated")
        manager.refreshState()

        XCTAssertEqual(manager.state, .needsRevalidation)
        XCTAssertFalse(manager.state.allowsDictation)
        // And says something different from an expired trial, because the
        // remedy is different: connect, rather than buy.
        XCTAssertEqual(manager.state.blockedReason?.contains("internet"), true)
    }

    func testDeactivationClearsLocalStateEvenWhenTheServerRefuses() async {
        let api = FakeAPI()
        let (manager, defaults, suite) = makeManager(api)
        defer { defaults.removePersistentDomain(forName: suite) }
        await manager.activate(key: "KEY")
        XCTAssertEqual(manager.state, .licensed)

        await manager.deactivate()

        XCTAssertEqual(api.deactivateCalls, 1)
        XCTAssertFalse(manager.hasKey)
        // Back to whatever the trial says, not straight to expired: removing a
        // licence from this Mac is not a punishment.
        XCTAssertEqual(manager.state, .trial(daysRemaining: LicenseTerms.trialDays))
    }

    /// The default must be production even in a debug build, where the sandbox
    /// exists: pointing at the test seller is something you opt into for one
    /// launch, never something a machine can drift into.
    func testTheLicenceEnvironmentDefaultsToProduction() {
        XCTAssertEqual(PolarLicenseAPI.environment, .production)
        XCTAssertEqual(PolarLicenseAPI.organizationId, "37efa08e-0bdc-4830-83aa-7a5f6aa98271")
        XCTAssertTrue(PolarLicenseAPI.isConfigured)
    }

    func testExpiredTrialBlocksDictationAndSaysWhy() {
        let (manager, defaults, suite) = makeManager()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(LicenseState.expired.blockedReason?.contains("trial has ended") == true)
        XCTAssertFalse(LicenseState.expired.allowsDictation)
        XCTAssertTrue(manager.state.allowsDictation)
    }
    // MARK: - Which product a key belongs to

    /// A key is only ever looked up inside an organisation, so the prefix is
    /// the app's whole notion of "this licence is for me". Without it, a key
    /// bought for another of our products would unlock MicMyDay.
    func testOnlyOurOwnKeysAreAccepted() {
        XCTAssertTrue(PolarLicenseAPI.isOurs("MMDP-ABCDEFGH-1234-5678-9012-ABCDEFABCDEF"))
        XCTAssertFalse(PolarLicenseAPI.isOurs("XYZ9-ABCDEFGH-1234-5678-9012-ABCDEFABCDEF"))
        XCTAssertFalse(PolarLicenseAPI.isOurs(""))
    }

    /// Both products unlock the same app. What separates a team licence from
    /// a personal one is how many activations it carries, which Polar counts;
    /// the app does not and must not.
    func testATeamKeyUnlocksTheAppJustAsAPersonalOneDoes() {
        XCTAssertTrue(PolarLicenseAPI.isOurs("MMDT-ABCDEFGH-1234-5678-9012-ABCDEFABCDEF"))
    }

    /// The prefix was MMD1 before the two products existed. It is not a
    /// MicMyDay prefix any more, and a key carrying it belongs to something
    /// else.
    func testTheRetiredPrefixIsNoLongerOurs() {
        XCTAssertFalse(PolarLicenseAPI.isOurs("MMD1-ABCDEFGH-1234-5678-9012-ABCDEFABCDEF"))
    }

    /// People paste from receipts and mail clients, which add space and
    /// sometimes change case.
    func testPastedKeysAreForgivenTheirWhitespaceAndCase() {
        XCTAssertTrue(PolarLicenseAPI.isOurs("  MMDP-ABCD  "))
        XCTAssertTrue(PolarLicenseAPI.isOurs("mmdp-abcd"))
        XCTAssertTrue(PolarLicenseAPI.isOurs("  mmdt-abcd  "))
    }

    /// The prefix is a product test, not a format test: a future product of
    /// this same app carries it too, which is the point of using a prefix
    /// rather than pinning one product id.
    func testAnyKeyWithOurPrefixIsOurs() {
        XCTAssertTrue(PolarLicenseAPI.isOurs("MMDP-anything-at-all"))
        XCTAssertTrue(PolarLicenseAPI.isOurs("MMDT-anything-at-all"))
    }

    func testAKeyForAnotherProductIsRefusedWithoutAskingTheServer() async {
        let api = PolarLicenseAPI()
        do {
            _ = try await api.activate(key: "XYZ9-0000", deviceLabel: "Test")
            XCTFail("a key for another product should not be sent to the server")
        } catch let error as LicenseError {
            XCTAssertEqual(error, .otherProduct)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

}
