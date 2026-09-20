import Foundation

/// Google's /models resource does not expose input/output modalities. Keep
/// exact, documented audio-to-text IDs here, then intersect with the live list.
/// Do not guess from "audio", "flash", or generateContent: those also match
/// speech generation, image models, and models needing a different transport.
/// Sources (checked 2026-09-08):
/// https://ai.google.dev/api/models
/// https://ai.google.dev/gemini-api/docs/models/{model-id}
/// https://ai.google.dev/gemini-api/docs/interactions-overview
enum GeminiModelCatalog {
    struct Model: Identifiable {
        let id: String
        let title: String
    }

    static let defaultModelID = "gemini-3.5-transcribe"
    static let models: [Model] = [
        Model(id: defaultModelID, title: "Gemini 3.5 Transcribe"),
        Model(id: "gemini-3.5-flash-lite", title: "Gemini 3.5 Flash-Lite"),
        Model(id: "gemini-3.8-flash", title: "Gemini 3.8 Flash"),
        Model(id: "gemini-3.7-flash", title: "Gemini 3.7 Flash"),
        Model(id: "gemini-3.6-flash", title: "Gemini 3.6 Flash"),
        Model(id: "gemini-3.5-flash", title: "Gemini 3.5 Flash"),
        Model(id: "gemini-3.1-flash-lite", title: "Gemini 3.1 Flash-Lite"),
        Model(id: "gemini-3.1-pro-preview", title: "Gemini 3.1 Pro Preview"),
        Model(id: "gemini-3-flash-preview", title: "Gemini 3 Flash Preview"),
        Model(id: "gemini-2.5-flash-lite", title: "Gemini 2.5 Flash-Lite"),
        Model(id: "gemini-2.5-flash", title: "Gemini 2.5 Flash"),
        Model(id: "gemini-2.5-pro", title: "Gemini 2.5 Pro"),
    ]

    static func model(withID id: String) -> Model? {
        models.first { $0.id == id }
    }

    static func transcriptionModels(in ids: [String]) -> [Model] {
        let available = Set(ids.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 })
        // An empty match stays empty. Falling back to the raw list would offer
        // models this engine cannot use. Unknown IDs need a catalog update.
        return models.filter { available.contains($0.id) }
    }

    static func fetchModels(
        apiKey: String, session: URLSession = ProviderNetworking.makeSession()
    ) async throws -> [Model] {
        var ids: [String] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            var request = try GeminiAPI.request(path: "models", apiKey: apiKey)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            request.url = components.url
            request.timeoutInterval = 30
            let data = try await GeminiAPI.responseData(for: request, session: session)
            let page = try JSONDecoder().decode(ModelPage.self, from: data)
            ids.append(contentsOf: (page.models ?? []).map(\.name))
            pageToken = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let pageToken, !seenTokens.insert(pageToken).inserted {
                throw TranscriptionError.invalidResponse
            }
        } while pageToken != nil
        return transcriptionModels(in: ids)
    }

    private struct ModelPage: Decodable {
        struct Entry: Decodable { let name: String }
        let models: [Entry]?
        let nextPageToken: String?
    }
}
