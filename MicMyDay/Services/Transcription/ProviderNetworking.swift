import Foundation

/// Shared transport policy for user-configured providers. HTTP is only for
/// local servers; internet providers must protect audio, text and credentials.
enum ProviderNetworking {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }

    static func validatedComponents(for baseURL: String) throws -> URLComponents {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw TranscriptionError.invalidConfiguration(
                "Enter an HTTP or HTTPS provider URL without a username, password, query or fragment. Put credentials in the key or headers fields."
            )
        }
        guard scheme == "https" || isLocalHost(host) else {
            throw TranscriptionError.invalidConfiguration(
                "Use HTTPS for internet providers. HTTP is supported only for localhost and local-network servers."
            )
        }
        return components
    }

    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" { return true }
        if host.contains(":") {
            let first = host.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
            guard let prefix = UInt16(first, radix: 16) else { return false }
            return (prefix & 0xfe00) == 0xfc00 || (prefix & 0xffc0) == 0xfe80
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            let octets = parts.map { UInt8($0)! }
            return octets[0] == 127 || octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254)
        }
        // Unqualified hostnames are resolved on the user's network.
        return !host.contains(".") && !host.isEmpty
            && host.contains(where: { $0.isLetter })
            && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
