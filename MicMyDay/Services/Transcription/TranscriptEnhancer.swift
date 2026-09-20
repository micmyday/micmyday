import Foundation
import OSLog

/// Appended to every rewrite system prompt so the model returns text, not
/// commentary. The prompts themselves live in RewriteProfile.
enum EnhancementOutput {
    static let instruction =
        "Output only the transformed text, with no preamble, quotation marks, or commentary."
}

struct EnhancementConfiguration {
    let baseURL: String
    let model: String
    let apiKey: String
    var systemPrompt: String
    var customHeaders: [CustomHeader] = []
    /// Runs through macOS's own language model instead of an endpoint. The
    /// URL, model and key are all empty in that case because there is nothing
    /// to address, authenticate or choose.
    var usesOnDeviceModel = false
    /// Which rewrite profile asked for this, so usage can be broken down by
    /// what the user was doing and not only by which model did it.
    var profileID: String = ""
    var profileName: String = ""
}

/// Post-processes a transcript through an OpenAI-compatible chat completions endpoint.
final class TranscriptEnhancer {
    /// Which model a rewrite actually went to is the first thing anyone asks
    /// when the text comes back looking untouched, and it was not answerable.
    private static let logger = Logger(subsystem: "com.micmyday.app", category: "Rewrite")

    private let session: URLSession
    private let requestConsent: (DataSharingRequest) async throws -> Void

    init(
        session: URLSession = ProviderNetworking.makeSession(),
        requestConsent: @escaping (DataSharingRequest) async throws -> Void = {
            request in try await MainActor.run {
                try DataSharingConsent.shared.requirePermission(for: request)
            }
        }
    ) {
        self.session = session
        self.requestConsent = requestConsent
    }

    /// `probe`, when given, receives what this rewrite consumed.
    func enhance(
        _ transcript: String,
        configuration: EnhancementConfiguration,
        probe: UsageProbe? = nil
    ) async throws -> String {
        // Nothing leaves the Mac on this path, so there is no endpoint to
        // build, no key to attach and no consent to ask for.
        if configuration.usesOnDeviceModel {
            // `model` names which local model, not an endpoint's model.
            let choice = RewriteModelCatalog.model(withID: configuration.model)
            guard let choice else {
                throw TranscriptionError.invalidConfiguration("Choose a model to rewrite with in Settings.")
            }
            if choice.isAppleBuiltIn {
                Self.logger.notice("rewriting with the model built into macOS")
                // Apple's framework reports no counts and does not expose its
                // tokenizer, so these are estimated from the text on both
                // sides and flagged as such. Recorded after the rewrite so a
                // failed one contributes nothing.
                let began = ContinuousClock.now
                let rewritten = try await AppleOnDeviceRewriter.rewrite(
                    transcript,
                    systemPrompt: configuration.systemPrompt
                )
                let elapsed = began.duration(to: .now).seconds
                probe?.add(UsageMeasurement(
                    job: .rewrite,
                    modelID: choice.id,
                    displayName: choice.displayName,
                    location: "This Mac",
                    tokensIn: UsageMeasurement.estimatedTokens(
                        in: configuration.systemPrompt + " " + transcript
                    ),
                    tokensOut: UsageMeasurement.estimatedTokens(in: rewritten),
                    wordsIn: UsageMeasurement.words(in: transcript),
                    wordsOut: UsageMeasurement.words(in: rewritten),
                    isEstimated: true,
                    processingSeconds: elapsed,
                    profileID: configuration.profileID,
                    profileName: configuration.profileName
                ))
                return rewritten
            }
            guard let download = choice.download,
                  let path = RewriteModelManager.localURL(forModelID: choice.id)?.path else {
                throw TranscriptionError.invalidConfiguration("\(choice.displayName) has not been downloaded yet.")
            }
            // Escape during a rewrite cancels the surrounding task; the engine
            // checks between tokens so generation stops with it rather than
            // running on to produce text nobody will see.
            Self.logger.notice("rewriting with \(choice.displayName, privacy: .public) on this Mac")
            // The engine reports its counts through a callback during the run;
            // the words can only be counted once the text exists, so the
            // measurement is assembled after the call rather than inside it.
            var counts: (Int, Int, Double) = (0, 0, 0)
            let rewritten = try await LlamaCppEngine.shared.rewrite(
                transcript: transcript,
                systemPrompt: configuration.systemPrompt,
                modelPath: path,
                format: download.format,
                counted: { tokensIn, tokensOut, seconds in
                    counts = (tokensIn, tokensOut, seconds)
                }
            )
            probe?.add(UsageMeasurement(
                job: .rewrite,
                modelID: choice.id,
                displayName: choice.displayName,
                location: "This Mac",
                tokensIn: counts.0,
                tokensOut: counts.1,
                wordsIn: UsageMeasurement.words(in: transcript),
                wordsOut: UsageMeasurement.words(in: rewritten),
                processingSeconds: counts.2,
                profileID: configuration.profileID,
                profileName: configuration.profileName
            ))
            return rewritten
        }
        guard !configuration.model.isEmpty else {
            throw TranscriptionError.invalidConfiguration("Enter an AI enhancement model name in Settings.")
        }

        let endpoint = try Self.chatCompletionsEndpoint(for: configuration.baseURL)
        let payload = ChatRequest(
            model: configuration.model,
            messages: [
                ChatMessage(
                    role: "system",
                    content: configuration.systemPrompt + "\n\n" + EnhancementOutput.instruction
                ),
                ChatMessage(role: "user", content: transcript),
            ]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for header in configuration.customHeaders where !header.value.isEmpty {
            let name = header.name.trimmingCharacters(in: .whitespaces)
            let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !header.value.contains("\r"), !header.value.contains("\n"),
                  !["host", "content-length", "connection", "transfer-encoding"].contains(name.lowercased()) else {
                throw TranscriptionError.invalidConfiguration("A custom header is invalid. Use a valid header name and a single-line value; transport headers are managed automatically.")
            }
            request.setValue(header.value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(payload)

        try await requestConsent(DataSharingRequest.provider(configuration.baseURL, content: .transcript))
        // Includes the network, which is part of the wait whether or not it is
        // part of the computation.
        let began = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = began.duration(to: .now).seconds
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw TranscriptionError.server(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        guard
            let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = decoded.choices.first?.message.content
        else {
            throw TranscriptionError.invalidResponse
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TranscriptionError.emptyResponse }
        // Cut off part way. The text reads as finished but is not, and for an
        // edit it would replace the user's whole passage with a fragment of it.
        guard decoded.choices.first?.finish_reason != "length" else {
            throw TranscriptionError.invalidConfiguration(
                "The model ran out of room before it finished. The original text was kept."
            )
        }
        // The provider counted these itself and put them in the body we have
        // already parsed, so this is free too.
        probe?.add(UsageMeasurement(
            job: .rewrite,
            modelID: configuration.model,
            displayName: configuration.model,
            location: endpoint.host ?? "a provider",
            tokensIn: decoded.usage?.prompt_tokens ?? 0,
            tokensOut: decoded.usage?.completion_tokens ?? 0,
            wordsIn: UsageMeasurement.words(in: transcript),
            wordsOut: UsageMeasurement.words(in: cleaned),
            processingSeconds: elapsed,
            profileID: configuration.profileID,
            profileName: configuration.profileName
        ))
        return cleaned
    }

    static func chatCompletionsEndpoint(for baseURL: String) throws -> URL {
        var components = try ProviderNetworking.validatedComponents(for: baseURL)

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        guard let endpoint = components.url else {
            throw TranscriptionError.invalidConfiguration("The enhancement endpoint URL could not be constructed.")
        }
        return endpoint
    }

    private static func errorMessage(from data: Data) -> String {
        if let response = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return response.error.message
        }
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let body, !body.isEmpty else { return "No error details were returned." }
        return String(body.prefix(500))
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        let message: ChatMessage
        /// "length" means the model was cut off by the token limit rather than
        /// finishing. Decoded leniently, like `usage`: a provider that omits it
        /// or sends something unexpected must not fail a response that is
        /// otherwise fine.
        var finish_reason: String?

        private enum CodingKeys: String, CodingKey {
            case message, finish_reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decode(ChatMessage.self, forKey: .message)
            finish_reason = try? container.decodeIfPresent(String.self, forKey: .finish_reason)
        }
    }

    /// Every OpenAI-compatible provider returns this, and it is the same
    /// quantity llama.cpp reports locally: tokens the model read, and tokens it
    /// wrote.
    ///
    /// Decoded leniently and separately from the rest. An optional property is
    /// only optional about being absent: a server that sends `"12"` where a
    /// number belongs would fail the whole response and throw away a rewrite
    /// that had already succeeded. Counters are never worth that.
    struct Usage: Decodable {
        var prompt_tokens: Int?
        var completion_tokens: Int?

        private enum CodingKeys: String, CodingKey {
            case prompt_tokens, completion_tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompt_tokens = try? container.decodeIfPresent(Int.self, forKey: .prompt_tokens)
            completion_tokens = try? container.decodeIfPresent(Int.self, forKey: .completion_tokens)
        }
    }

    let choices: [Choice]
    var usage: Usage?

    private enum CodingKeys: String, CodingKey {
        case choices, usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decode([Choice].self, forKey: .choices)
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}
