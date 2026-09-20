import Foundation
import Security

struct KeychainStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
            }
        }
    }

    // macOS carries two keychains, and which one is used decides whether the
    // user is ever asked for permission.
    //
    // The login keychain guards each item with a list of the programs allowed
    // to read it, and it counts every rebuild as a different program, so a
    // developer is asked again after each one. The data-protection keychain,
    // the one iOS uses, grants access by the app's signature instead: the same
    // team and bundle identifier read silently and anything else is refused
    // without troubling anybody.
    //
    // A shipped build uses the second, so no customer ever sees a keychain
    // prompt. It refuses an app carrying no provisioning profile, which a
    // debug build deliberately does not have, so those keep the login keychain
    // and the prompts that come with it. Nothing else differs: same service,
    // same accounts, same calls.
    private static let usesDataProtectionKeychain: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    private let service: String

    /// True when this process is the unit-test host.
    ///
    /// Under the harness no Security call is ever made: every store, whatever
    /// its service, reads and writes the in-memory dictionary below instead.
    /// Anything less proved unlivable. The earlier version only skipped the
    /// app's own service and left the tests' private services on the real
    /// keychain, where every run deposited items owned by that day's binary;
    /// the next day's differently-hashed test host touching them raised one
    /// password prompt per item, by the hundred. The tests only ever need
    /// set/get/delete to round-trip, and the dictionary gives them exactly
    /// that.
    private static let underTestHarness =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static let harnessLock = NSLock()
    nonisolated(unsafe) private static var harnessValues: [String: String] = [:]

    private func harnessKey(_ account: String) -> String { "\(service)\u{1F}\(account)" }

    init(service: String = Bundle.main.bundleIdentifier ?? "com.micmyday.app") {
        self.service = service
    }

    func get(account: String) throws -> String? {
        if Self.underTestHarness {
            Self.harnessLock.lock()
            defer { Self.harnessLock.unlock() }
            return Self.harnessValues[harnessKey(account)]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: Self.usesDataProtectionKeychain,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, account: String) throws {
        if Self.underTestHarness {
            Self.harnessLock.lock()
            defer { Self.harnessLock.unlock() }
            if value.isEmpty {
                Self.harnessValues[harnessKey(account)] = nil
            } else {
                Self.harnessValues[harnessKey(account)] = value
            }
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: Self.usesDataProtectionKeychain
        ]

        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // Readable once the Mac has been unlocked after starting up, and
            // never off this Mac: not synced, not in a backup. A licence
            // activation belongs to one machine by definition, and an API key
            // is not something to copy elsewhere on the user's behalf.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }
}
