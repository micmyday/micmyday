import Foundation

/// Lists the models an OpenAI-compatible endpoint offers. Doubles as the key
/// check: a wrong key fails here with the provider's own error message before
/// the key is ever used for a rewrite.
enum ProviderModelCatalog {
    static func fetchModelIDs(
        baseURL: String,
        apiKey: String,
        headers: [CustomHeader] = [],
        session: URLSession = ProviderNetworking.makeSession()
    ) async throws -> [String] {
        var components = try ProviderNetworking.validatedComponents(for: baseURL)
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/models") { path += "/models" }
        components.path = path
        guard let url = components.url else {
            throw TranscriptionError.invalidConfiguration("The provider URL could not be constructed.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Listing models is Anthropic's own endpoint rather than part of its
        // OpenAI-compatible surface, and it authenticates differently: a bare
        // Bearer token is refused with "invalid x-api-key", which is the
        // service telling us which header it wanted. The version is required
        // too. Both are sent only to that host, because a header invented for
        // one provider has no business going to another.
        if url.host?.hasSuffix("anthropic.com") == true, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !header.value.isEmpty,
                  !["host", "content-length", "connection", "transfer-encoding"].contains(name.lowercased())
            else { continue }
            request.setValue(header.value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TranscriptionError.server(statusCode: http.statusCode, message: errorMessage(from: data))
        }
        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    /// Model ids that make sense for rewriting text; the raw list carries
    /// embeddings, audio, and image models that would only mislead.
    static func chatModels(in ids: [String]) -> [String] {
        let excluded = [
            "embedding", "whisper", "tts", "dall-e", "audio", "realtime",
            "transcribe", "moderation", "image", "davinci", "babbage",
            "computer-use", "codex", "search",
        ]
        let filtered = ids.filter { id in
            let lowered = id.lowercased()
            return !excluded.contains { lowered.contains($0) }
        }
        return filtered.isEmpty ? ids : filtered
    }

    /// Model ids that can take audio in and give text back; everything else
    /// on the list would fail at /audio/transcriptions.
    static func transcriptionModels(in ids: [String]) -> [String] {
        let wanted = ["transcribe", "whisper"]
        let filtered = ids.filter { id in
            let lowered = id.lowercased()
            return wanted.contains { lowered.contains($0) }
        }
        return filtered.isEmpty ? ids : filtered
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct APIError: Decodable { let message: String }
            let error: APIError
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return envelope.error.message
        }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let body, !body.isEmpty else { return "No error details were returned." }
        return String(body.prefix(500))
    }
}
