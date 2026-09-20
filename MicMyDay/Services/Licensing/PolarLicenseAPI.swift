import Foundation
import os

/// Errors worth telling the user apart, because the remedy differs.
enum LicenseError: LocalizedError, Equatable {
    case notConfigured
    case activationsNotEnabled
    case unknownKey
    case otherProduct
    case seatsExhausted(limit: Int)
    case revoked
    case offline
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no licence server configured, so keys cannot be checked. That is a packaging mistake rather than anything you did."
        case .activationsNotEnabled:
            return "This licence was issued without a device limit, so it cannot be tied to a Mac. Reply to your purchase receipt and we will reissue it."
        case .unknownKey:
            return "That licence key was not recognised. Check it for typos, or paste it again from your receipt."
        case .otherProduct:
            return "That is a valid key, but not for MicMyDay. Check that you copied the key from the right receipt."
        case let .seatsExhausted(limit):
            return "This key is already in use on \(limit) \(limit == 1 ? "Mac" : "Macs"). Open MicMyDay's Licence settings on one of them and press Deactivate. If you no longer have that Mac, reply to your purchase receipt and we will free it for you."
        case .revoked:
            return "This licence is no longer active. If that is unexpected, reply to your purchase receipt and we will sort it out."
        case .offline:
            return "MicMyDay could not reach the licence server. Check your connection and try again."
        case let .server(status):
            return "The licence server answered unexpectedly (error \(status)). Try again in a moment."
        }
    }
}

/// What a licence check tells us about this machine.
struct LicenseActivation: Equatable {
    let activationId: String
    /// How many machines the key covers, when the seller has set a limit.
    let seatLimit: Int?
}

/// The licence backend, behind a protocol so the app never depends on one
/// vendor's shape and the manager can be tested without a network.
protocol LicenseAPI: Sendable {
    /// Activates this key for this machine, returning the activation to store.
    func activate(key: String, deviceLabel: String) async throws -> LicenseActivation
    /// Confirms a stored key and activation are both still good.
    func validate(key: String, activationId: String) async throws
    /// Releases this machine's seat so it can be used on another.
    func deactivate(key: String, activationId: String) async throws
}

/// Polar.sh, talked to directly from the app.
///
/// There is no server of ours in between, which means there is no server of
/// ours to run, secure or have go down. The organisation id is not a secret:
/// it identifies who the key belongs to, and every endpoint used here is part
/// of Polar's customer portal API, which is designed to be called by clients.
struct PolarLicenseAPI: LicenseAPI {
    /// Which Polar to talk to.
    ///
    /// The sandbox case exists only in debug builds. That is the point: a
    /// release binary cannot select the sandbox because the sandbox does not
    /// exist in it, and the test organisation id is never compiled in, so it
    /// cannot be shipped by accident or found by anyone reading the binary.
    /// A runtime flag alone would not give that guarantee.
    enum Environment {
        case production
        #if DEBUG
        case sandbox
        #endif

        var organizationId: String {
            switch self {
            case .production: return "37efa08e-0bdc-4830-83aa-7a5f6aa98271"
            #if DEBUG
            case .sandbox: return "115b9865-a36e-405f-91e8-a146d65b48ca"
            #endif
            }
        }

        /// Where a customer signs in to see their purchase and their keys.
        /// Polar mails them a link rather than holding a password, so this is
        /// safe to open from the app without asking for anything first.
        ///
        /// Only production has a portal worth linking to: the sandbox
        /// organisation is a test seller with no real customers, so a debug
        /// build sends you to the same page rather than a dead one.
        var portalURL: URL {
            URL(string: "https://polar.sh/micmyday/portal/request")!
        }

        var baseURL: URL {
            switch self {
            case .production:
                return URL(string: "https://api.polar.sh/v1/customer-portal/license-keys")!
            #if DEBUG
            case .sandbox:
                return URL(string: "https://sandbox-api.polar.sh/v1/customer-portal/license-keys")!
            #endif
            }
        }
    }

    /// Production unless a debug build is explicitly told otherwise. Opting in
    /// takes a deliberate act every launch, so a machine cannot be left pointing
    /// at the sandbox by a setting somebody forgot about:
    ///
    ///     MICMYDAY_POLAR_SANDBOX=1 open -a MicMyDay
    static let environment: Environment = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MICMYDAY_POLAR_SANDBOX"] == "1" {
            return .sandbox
        }
        #endif
        return .production
    }()

    /// Every MicMyDay key begins with one of these.
    ///
    /// A key is only ever looked up inside an organisation, so without a test
    /// of its own every key that organisation has ever issued would unlock
    /// this app, including one bought for something else entirely. The prefix
    /// is set on the product in Polar and is the app's whole notion of "this
    /// licence is for me". Deliberately a prefix rather than a pinned product
    /// or benefit id: new products and benefits for this same app, an upgrade
    /// or a bundle, keep working without shipping a new build.
    ///
    /// One per product: `MMDP` for a personal licence, `MMDT` for a team one.
    /// The app treats them alike, because what separates them is how many
    /// activations the key carries, and Polar counts those itself. Nothing
    /// here has to know that a team key has twenty seats, and nothing here
    /// should: a seat limit enforced in a client is a seat limit enforced
    /// nowhere.
    static let keyPrefixes = ["MMDP", "MMDT"]

    static var organizationId: String { environment.organizationId }
    static var portalURL: URL { environment.portalURL }

    private let baseURL = PolarLicenseAPI.environment.baseURL
    private let session: URLSession
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.micmyday.app",
        category: "Licence"
    )

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Wire types

    private struct ActivateBody: Encodable {
        let key: String
        let organization_id: String
        let label: String
    }

    private struct ValidateBody: Encodable {
        let key: String
        let organization_id: String
        let activation_id: String
    }

    private struct DeactivateBody: Encodable {
        let key: String
        let organization_id: String
        let activation_id: String
    }

    private struct ActivationEnvelope: Decodable {
        let id: String
        let license_key: KeyInfo?

        struct KeyInfo: Decodable {
            let status: String?
            let limit_activations: Int?
        }
    }

    private struct ValidationEnvelope: Decodable {
        let status: String?
        let limit_activations: Int?
    }

    // MARK: - Calls

    /// True once a real organisation id has been set. A build shipped with the
    /// placeholder would send every key to Polar under a nonexistent seller and
    /// report each one as invalid, which looks to the user like their key is
    /// broken. Better to name the real fault.
    static var isConfigured: Bool { !organizationId.hasPrefix("REPLACE_WITH") }

    /// Whether a key was issued for this app. Case and surrounding space are
    /// forgiven because people paste from receipts and mail clients.
    static func isOurs(_ key: String) -> Bool {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return keyPrefixes.contains { cleaned.hasPrefix($0) }
    }

    func activate(key: String, deviceLabel: String) async throws -> LicenseActivation {
        guard Self.isConfigured else { throw LicenseError.notConfigured }
        // Before the request, not after it: a key for another of our products
        // would otherwise be activated here, spending one of its seats on an
        // app it was never bought for.
        guard Self.isOurs(key) else { throw LicenseError.otherProduct }
        let body = ActivateBody(
            key: key.trimmed,
            organization_id: Self.organizationId,
            label: deviceLabel
        )
        let envelope: ActivationEnvelope = try await post("activate", body: body)
        if let status = envelope.license_key?.status, status != "granted" {
            throw LicenseError.revoked
        }
        return LicenseActivation(
            activationId: envelope.id,
            seatLimit: envelope.license_key?.limit_activations
        )
    }

    func validate(key: String, activationId: String) async throws {
        guard Self.isConfigured else { throw LicenseError.notConfigured }
        let body = ValidateBody(
            key: key.trimmed,
            organization_id: Self.organizationId,
            activation_id: activationId
        )
        let envelope: ValidationEnvelope = try await post("validate", body: body)
        guard envelope.status == "granted" else { throw LicenseError.revoked }
    }

    func deactivate(key: String, activationId: String) async throws {
        let body = DeactivateBody(
            key: key.trimmed,
            organization_id: Self.organizationId,
            activation_id: activationId
        )
        // Deactivation returns no body worth reading; only the status matters.
        _ = try await send(request(for: "deactivate", body: body))
    }

    // MARK: - Transport

    private func request<Body: Encodable>(for path: String, body: Body) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A licence check must never hold up the app for long: everything that
        // depends on it has a cached answer to fall back on.
        request.timeoutInterval = 12
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String, body: Body
    ) async throws -> Response {
        let data = try await send(try request(for: path, body: body))
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Self.logger.error("licence response could not be read: \(error.localizedDescription, privacy: .public)")
            throw LicenseError.server(status: 200)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Anything that stopped us reaching the server is offline as far as
            // the user is concerned, and the grace period covers it.
            throw LicenseError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseError.offline }
        switch http.statusCode {
        case 200 ... 299:
            return data
        case 404:
            throw LicenseError.unknownKey
        case 403, 409:
            // Several situations share these codes, so the body decides rather
            // than the status alone.
            let body = String(data: data, encoding: .utf8)?.lowercased() ?? ""
            // A key issued with no activation limit: Polar refuses the
            // activation endpoint outright. That is the seller's configuration,
            // not the customer's key, and telling them it is "in use on 0 Macs"
            // would send them chasing a problem they cannot fix.
            if body.contains("does not support activations") {
                Self.logger.error("licence key has no activation limit set on the Polar product")
                throw LicenseError.activationsNotEnabled
            }
            if body.contains("activation") || http.statusCode == 409 {
                let limit = (try? JSONDecoder().decode(ValidationEnvelope.self, from: data))?.limit_activations
                throw LicenseError.seatsExhausted(limit: limit ?? 0)
            }
            throw LicenseError.revoked
        case 422:
            // A malformed request, which means this build is sending something
            // Polar does not accept. Reporting it as a key problem would send
            // the user hunting for a typo that is not there.
            Self.logger.error("licence request rejected as invalid: \(String(data: data, encoding: .utf8) ?? "", privacy: .public)")
            throw LicenseError.server(status: 422)
        default:
            Self.logger.error("licence server returned \(http.statusCode)")
            throw LicenseError.server(status: http.statusCode)
        }
    }
}

private extension String {
    /// Keys get pasted with stray whitespace far more often than not.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
