import AppKit
import Foundation
import os

/// Owns everything about entitlement: the trial clock, the stored key, and when
/// to talk to the licence server.
///
/// Two rules shape the design. Dictation must never wait on the network, so
/// every gate reads cached state and revalidation happens in the background.
/// And a paid copy must not stop working because a server is unreachable, so a
/// validated licence keeps going for `offlineGraceDays` without contact.
@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var state: LicenseState = .trial(daysRemaining: LicenseTerms.trialDays)
    /// Set while a key is being checked, so the UI can show progress.
    @Published private(set) var isWorking = false
    /// The most recent failure, for the licence screen to show.
    @Published var lastError: LicenseError?
    /// How many machines the key covers, once we know.
    @Published private(set) var seatLimit: Int?

    private let api: LicenseAPI
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "Licence"
    )

    /// The key and its activation live in the Keychain, not in preferences:
    /// they are credentials, and they should survive a preferences reset while
    /// still being removable by the user.
    ///
    /// A debug build pointed at the sandbox stores its credentials under their
    /// own names. Both builds share a bundle identifier, so without this they
    /// share one slot: a release build would find a sandbox key, fail to
    /// validate it against the real server, read the 404 as revoked and erase
    /// it. That can only happen on a development machine, but it erases the
    /// licence quietly and looks exactly like a bug in activation.
    private enum Account {
        static let key = "licence-key" + environmentSuffix
        static let activation = "licence-activation-id" + environmentSuffix
        // The trial clock is deliberately shared. It is not tied to an
        // environment, and giving debug builds their own would hand out a fresh
        // trial whenever one was launched.
        static let trialStart = "licence-trial-start"

        static let environmentSuffix: String = {
            #if DEBUG
            if PolarLicenseAPI.environment == .sandbox { return "-sandbox" }
            #endif
            return ""
        }()
    }

    /// Only the timestamps live in preferences. They are not secrets, and a
    /// user who clears them gains nothing: the trial start is in the Keychain.
    /// These are separated per environment for the same reason as the keys.
    private enum Key {
        static let lastValidated = "licenceLastValidated" + Account.environmentSuffix
        static let seatLimit = "licenceSeatLimit" + Account.environmentSuffix
    }

    init(
        api: LicenseAPI = PolarLicenseAPI(),
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.keychain = keychain
        self.defaults = defaults
        seatLimit = defaults.object(forKey: Key.seatLimit) as? Int
        refreshState()
    }

    var hasKey: Bool { storedKey != nil }

    /// The stored key, masked for display. Never show a key in full in a UI
    /// that might end up in a screenshot on a support thread.
    var maskedKey: String? {
        guard let key = storedKey, key.count > 8 else { return storedKey }
        return String(key.prefix(4)) + String(repeating: "•", count: 8) + String(key.suffix(4))
    }

    // MARK: - Entitlement

    /// Recomputes the state from what is stored. Cheap, synchronous and does no
    /// networking, so it is safe to call from anywhere, including a gate on the
    /// recording path.
    func refreshState() {
        #if LOCAL_BUILD
        // Built from source. The source is GPL-3.0 and anyone may compile and
        // run it, so a build made this way is entitled by definition and
        // never asks for a key or counts a trial. What the paid download buys
        // is the prepared article: signed, notarised, installed by dragging,
        // updating itself, and supported. Not the right to run the code.
        state = .licensed
        return
        #else
        if storedKey != nil, storedActivationId != nil {
            let since = lastValidated ?? .distantPast
            let elapsed = Date().timeIntervalSince(since)
            let grace = TimeInterval(LicenseTerms.offlineGraceDays) * 24 * 60 * 60
            state = elapsed <= grace ? .licensed : .needsRevalidation
            return
        }

        let remaining = trialDaysRemaining()
        state = remaining > 0 ? .trial(daysRemaining: remaining) : .expired
        #endif
    }

    /// Whether this build was compiled from source rather than downloaded.
    /// Read by the parts of the interface that would otherwise offer to sell
    /// something to somebody who has already built it themselves.
    nonisolated static var isLocalBuild: Bool {
        #if LOCAL_BUILD
        true
        #else
        false
        #endif
    }

    /// Whole days left, counting the day the trial started as day one.
    private func trialDaysRemaining() -> Int {
        let start = trialStart ?? beginTrial()
        // A start date in the future means the clock moved, by accident or on
        // purpose. Treat it as starting now rather than granting a longer trial.
        let effectiveStart = min(start, Date())
        let elapsedDays = Calendar.current.dateComponents(
            [.day], from: effectiveStart, to: Date()
        ).day ?? 0
        return max(0, LicenseTerms.trialDays - elapsedDays)
    }

    /// Starts the clock the first time the app runs, and records it in the
    /// Keychain so reinstalling does not hand out a second trial.
    @discardableResult
    private func beginTrial() -> Date {
        let now = Date()
        store(now.timeIntervalSince1970.description, account: Account.trialStart)
        return now
    }

    // MARK: - Actions

    /// Validates and activates a key the user has entered.
    func activate(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Already in flight. Without this, pressing Return and clicking Activate
        // both fire, and each one burns a seat on a key that may only have
        // three.
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        // This Mac already holds an activation for this key: confirm it rather
        // than asking for another. Every activation consumes a seat, so
        // re-entering the same key on the same machine used to cost the user a
        // Mac's worth of licence each time.
        if trimmed == storedKey, let activation = storedActivationId {
            do {
                try await api.validate(key: trimmed, activationId: activation)
                markValidated()
                refreshState()
                return
            } catch LicenseError.unknownKey, LicenseError.revoked {
                // The stored activation is no longer good, so fall through and
                // register this machine again.
                forgetLicence()
            } catch let error as LicenseError {
                lastError = error
                return
            } catch {
                lastError = .offline
                return
            }
        }

        do {
            let activation = try await api.activate(key: trimmed, deviceLabel: Self.deviceLabel)
            store(trimmed, account: Account.key)
            store(activation.activationId, account: Account.activation)
            seatLimit = activation.seatLimit
            defaults.set(activation.seatLimit, forKey: Key.seatLimit)
            markValidated()
            refreshState()
            Self.logger.info("licence activated")
        } catch let error as LicenseError {
            lastError = error
        } catch {
            lastError = .offline
        }
    }

    /// Releases this machine's seat and forgets the key, so it can be used
    /// somewhere else. Local state is cleared even if the server call fails,
    /// because the user asked to remove it from *this* Mac.
    func deactivate() async {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        if let key = storedKey, let activation = storedActivationId {
            do {
                try await api.deactivate(key: key, activationId: activation)
            } catch let error as LicenseError {
                lastError = error
            } catch {
                lastError = .offline
            }
        }
        forgetLicence()
        refreshState()
    }

    /// Re-checks in the background if it has been a while. Never surfaces an
    /// error: a failed background check simply leaves the last success standing
    /// until the grace period runs out.
    func revalidateIfDue() {
        guard let key = storedKey, let activation = storedActivationId else { return }
        let since = lastValidated ?? .distantPast
        guard Date().timeIntervalSince(since) > LicenseTerms.revalidateEvery else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.api.validate(key: key, activationId: activation)
                self.markValidated()
                self.refreshState()
            } catch LicenseError.revoked, LicenseError.unknownKey {
                // The seller withdrew it or it was refunded. Clearing is right:
                // leaving a dead key in place would keep failing silently until
                // the grace period ended, which is a worse way to find out.
                Self.logger.info("licence no longer valid, clearing")
                self.forgetLicence()
                self.refreshState()
            } catch {
                Self.logger.info("background licence check failed, grace period continues")
            }
        }
    }

    // MARK: - Storage

    private var storedKey: String? { read(Account.key) }
    private var storedActivationId: String? { read(Account.activation) }

    private var trialStart: Date? {
        guard let raw = read(Account.trialStart), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private var lastValidated: Date? {
        defaults.object(forKey: Key.lastValidated) as? Date
    }

    private func markValidated() {
        defaults.set(Date(), forKey: Key.lastValidated)
    }

    private func forgetLicence() {
        store("", account: Account.key)
        store("", account: Account.activation)
        defaults.removeObject(forKey: Key.lastValidated)
        defaults.removeObject(forKey: Key.seatLimit)
        seatLimit = nil
    }

    /// What has already been read, so nothing is read twice.
    ///
    /// The outer optional is "have we looked", the inner one "was anything
    /// there", which is why an absent item still earns an entry.
    private var cache: [String: String?] = [:]

    /// Reads an item once per launch and remembers the answer.
    ///
    /// `storedKey` and `storedActivationId` are computed properties, so every
    /// glance at the licence used to be a keychain call: opening the menu bar
    /// panel, drawing a pane, asking whether a key exists. On a Mac where the
    /// items were written by a differently signed build, each of those calls
    /// raises a password prompt, so the app asked again and again for the same
    /// secret it had already been given. Reading through a cache makes the
    /// worst case one prompt per item for the life of the process.
    ///
    /// Safe to cache because this app is the only thing that writes these
    /// items, and every write below refreshes the entry it touched.
    private func read(_ account: String) -> String? {
        if let cached = cache[account] { return cached }
        let value = try? keychain.get(account: account)
        let result = (value?.isEmpty ?? true) ? nil : value
        cache[account] = result
        return result
    }

    private func store(_ value: String, account: String) {
        try? keychain.set(value, account: account)
        cache[account] = value.isEmpty ? nil : value
    }

    /// What the seat is called in the customer's Polar portal, so they can tell
    /// their machines apart when deactivating one.
    private static var deviceLabel: String {
        Host.current().localizedName ?? "Mac"
    }
}
