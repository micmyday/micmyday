import Foundation

final class OpenAICompatibleTranscriber {
    private let session: URLSession

    init(session: URLSession = ProviderNetworking.makeSession()) {
        self.session = session
    }

    /// Streams the transcript as the provider produces it.
    ///
    /// Note this streams the *model's output* after the recording has been
    /// uploaded, not audio while the user speaks: text arrives progressively
    /// rather than in one lump. `onDelta` receives each new fragment on the
    /// main actor; the full text is returned when the stream finishes.
    ///
    /// A failure *before the first fragment* falls back to a normal request, so
    /// a provider that ignores `stream=true`, or a proxy that buffers the
    /// response, still transcribes. Once fragments have been handed over the
    /// fallback is off: the caller may already have pasted them, a retry costs
    /// the user a second billed request, and a model is free to word the retry
    /// differently, which would leave the two versions disagreeing.
    func transcribeStreaming(
        fileURL: URL,
        configuration: TranscriptionConfiguration,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard Self.modelCanStream(configuration.model) else {
            return try await transcribe(fileURL: fileURL, configuration: configuration)
        }
        var emittedAnything = false
        do {
            return try await streamTranscript(
                fileURL: fileURL,
                configuration: configuration,
                onDelta: { delta in
                    emittedAnything = true
                    onDelta(delta)
                }
            )
        } catch let unsupported as StreamingUnsupported {
            // The provider or model does not stream. Nothing was delivered, so
            // a plain request is safe and is the only way to get a transcript.
            guard !emittedAnything else {
                if case .server(let error) = unsupported { throw error }
                throw TranscriptionError.invalidResponse
            }
            return try await transcribe(fileURL: fileURL, configuration: configuration)
        }
    }

    private func streamTranscript(
        fileURL: URL,
        configuration: TranscriptionConfiguration,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let request = try Self.buildRequest(fileURL: fileURL, configuration: configuration, streaming: true)
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let failure = TranscriptionError.server(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: body)
            )
            // Only a rejected request argues that `stream=true` is the problem
            // and is worth retrying without it. A server fault or a rate limit
            // says nothing about streaming, and retrying those can bill the
            // user for a second transcription of the same audio.
            guard Self.rejectsTheRequest(httpResponse.statusCode) else { throw failure }
            throw StreamingUnsupported.server(failure)
        }

        var parser = SSEParser()
        var assembled = ""
        var finalText: String?
        var sawTerminator = false
        var sawAnyEvent = false
        var rawBody = Data()

        // Deliberately not `bytes.lines`: Foundation's line sequence discards
        // empty lines, and in server-sent events the blank line *is* the event
        // separator. Using it meant no event was ever dispatched, so streaming
        // produced nothing and silently fell back to a second billed request.
        var line = Data()
        var lastByteWasCarriageReturn = false
        var isFirstLine = true

        // Deltas are collected first and handed over after, so the callback
        // never runs while the parser is mid-event.
        var pendingDeltas: [String] = []

        func handle(_ event: SSEParser.Event) throws {
            sawAnyEvent = true
            switch try Self.interpret(event, statusCode: httpResponse.statusCode) {
            case .delta(let text):
                guard !text.isEmpty else { break }
                assembled += text
                // The fragment is recorded as it came in. Recovering it by
                // comparing lengths before and after would corrupt text: those
                // count graphemes, and a delta beginning with a combining mark
                // extends the previous grapheme rather than adding one, so the
                // accent in a split "Cafe" + "\u{0301}" would be dropped.
                pendingDeltas.append(text)
            case .completed(let text):
                if let text { finalText = text }
                sawTerminator = true
            case .ignored:
                break
            }
        }

        func finishLine() throws {
            var text = String(decoding: line, as: UTF8.self)
            // A byte-order mark on the very first line would stop the first
            // field from being recognised, losing the opening words.
            if isFirstLine {
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                isFirstLine = false
            }
            line.removeAll(keepingCapacity: true)
            guard let event = parser.consume(text) else { return }
            try handle(event)
        }

        for try await byte in bytes {
            rawBody.append(byte)
            if byte == 0x0D {
                try finishLine()
                lastByteWasCarriageReturn = true
            } else if byte == 0x0A {
                // The second half of a CRLF pair; the line already ended.
                if lastByteWasCarriageReturn {
                    lastByteWasCarriageReturn = false
                    continue
                }
                try finishLine()
            } else {
                lastByteWasCarriageReturn = false
                line.append(byte)
            }
            for delta in pendingDeltas { await MainActor.run { onDelta(delta) } }
            pendingDeltas.removeAll(keepingCapacity: true)
            if sawTerminator { break }
        }
        if !sawTerminator, !line.isEmpty { try finishLine() }
        // A stream that ends without a closing blank line still has one event
        // gathered but not dispatched.
        if !sawTerminator, let event = parser.flush() { try handle(event) }
        for delta in pendingDeltas { await MainActor.run { onDelta(delta) } }

        // The provider answered 200 with a normal transcription body rather
        // than a stream. That is a success, not a failure: use it directly
        // instead of throwing away a transcript the user already paid for.
        if !sawAnyEvent {
            // A body the server labelled as a stream, yet which held no events
            // (only keep-alive comments, say), is a failed transcription. It
            // must not be handed back as text: the raw protocol bytes would be
            // pasted, and auto-send would submit them.
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("text/event-stream") {
                throw TranscriptionError.emptyResponse
            }
            guard let text = Self.plainTranscript(from: rawBody) else {
                throw StreamingUnsupported.notAStream
            }
            return text
        }

        // Deltas but no completion event means the connection dropped
        // mid-transcript. Returning the partial text as if it were finished
        // would hand the user half a sentence, and auto-send would submit it.
        guard sawTerminator else {
            throw TranscriptionError.server(
                statusCode: httpResponse.statusCode,
                message: "The transcript stopped before it was complete."
            )
        }

        let text = finalText ?? assembled
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionError.emptyResponse
        }
        return text
    }

    /// What one parsed event means, independent of which provider sent it.
    private enum StreamOutcome {
        case delta(String)
        case completed(String?)
        case ignored
    }

    /// Maps a provider's event onto `StreamOutcome`.
    ///
    /// OpenAI-compatible servers disagree on both the event names and which
    /// field holds the text. One sends `transcript.text.delta` with the new
    /// text in `delta`; another sends `transcription.text.delta` with it in
    /// `text`, and closes with `transcription.done` where `text` is the whole
    /// transcript. Reading one shape only would silently drop the other's
    /// transcript, and a custom endpoint may be either.
    private static func interpret(
        _ event: SSEParser.Event,
        statusCode: Int
    ) throws -> StreamOutcome {
        if event.data == "[DONE]" { return .completed(nil) }

        let decoded = event.data.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(StreamEvent.self, from: $0)
        }

        // Checked before decoding succeeds: a provider may name the event
        // `error` and put a bare string in the data, which is not a StreamEvent
        // at all. Treating that as unparseable would hide the failure and let
        // the words received so far pass as a finished transcript.
        if event.name == "error" || decoded?.error != nil || decoded?.type == "error" {
            throw TranscriptionError.server(
                statusCode: statusCode,
                message: decoded?.error?.message
                    ?? Self.readableMessage(from: event.data)
                    ?? "The provider reported an error mid-transcript."
            )
        }
        guard let decoded else { return .ignored }

        switch decoded.type {
        case "transcript.text.delta":
            return .delta(decoded.delta ?? "")
        case "transcription.text.delta":
            return .delta(decoded.text ?? "")
        case "transcript.text.done", "transcription.done":
            return .completed(decoded.text)
        default:
            return .ignored
        }
    }

    /// Whether the status means the provider refused this request as written,
    /// rather than failing to serve it.
    private static func rejectsTheRequest(_ statusCode: Int) -> Bool {
        [400, 404, 405, 415, 422].contains(statusCode)
    }

    /// Models known not to support `stream=true`.
    ///
    /// OpenAI documents streaming for the gpt-4o transcribe models but excludes
    /// whisper-1, so asking would spend a request to learn what is already
    /// known.
    static func modelCanStream(_ model: String) -> Bool {
        let name = model.lowercased()
        return !name.hasPrefix("whisper-1") && !name.contains("whisper-large")
    }

    /// Reads an ordinary (non-streaming) transcription body.
    private static func plainTranscript(from data: Data) -> String? {
        if
            let object = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
            !object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return object.text
        }
        // Same shapes the non-streaming path accepts. Discarding a plain-text
        // transcript here would re-upload audio the provider has already
        // transcribed and charged for.
        if
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            !text.hasPrefix("{")
        {
            return text
        }
        return nil
    }

    /// A human-readable message from an error payload that is not a
    /// StreamEvent, such as a bare string or a differently shaped envelope.
    private static func readableMessage(from payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            return Self.errorMessage(from: data)
        }
        return trimmed
    }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        guard !configuration.model.isEmpty else {
            throw TranscriptionError.invalidConfiguration("Enter a transcription model name in Settings.")
        }
        if configuration.provider.requiresAPIKey, configuration.apiKey.isEmpty {
            throw TranscriptionError.invalidConfiguration(
                "Enter a \(configuration.provider.title) key in Settings → Engine."
            )
        }

        let request = try Self.buildRequest(fileURL: fileURL, configuration: configuration, streaming: false)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw TranscriptionError.server(
                statusCode: httpResponse.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        if
            let object = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
            !object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return object.text
        }
        if
            let plainText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !plainText.isEmpty,
            !plainText.hasPrefix("{")
        {
            return plainText
        }
        throw TranscriptionError.emptyResponse
    }

    /// Builds the multipart upload for one recording.
    ///
    /// `streaming` adds `stream=true`, which switches the response from a JSON
    /// body to server-sent `transcript.text.delta` / `transcript.text.done`
    /// events.
    static func buildRequest(
        fileURL: URL,
        configuration: TranscriptionConfiguration,
        streaming: Bool
    ) throws -> URLRequest {
        let endpoint = try transcriptionEndpoint(for: configuration.baseURL)
        let audio = try Data(contentsOf: fileURL)
        guard !audio.isEmpty else { throw TranscriptionError.emptyResponse }

        var form = MultipartFormData()
        form.addField(name: "model", value: configuration.model)
        form.addFile(name: "file", filename: "recording.wav", mimeType: "audio/wav", contents: audio)
        if !configuration.language.isEmpty {
            form.addField(name: "language", value: configuration.language)
        }
        if !configuration.prompt.isEmpty {
            form.addField(name: "prompt", value: configuration.prompt)
        }
        form.addField(name: "response_format", value: "json")
        if streaming {
            form.addField(name: "stream", value: "true")
        }
        form.finalize()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.data
        return request
    }

    /// One server-sent event from a streaming transcription.
    struct StreamEvent: Decodable {
        /// Providers send this either as `{"message": "..."}` or as a bare
        /// string, so both have to decode.
        struct Failure: Decodable {
            let message: String?

            init(from decoder: Decoder) throws {
                if
                    let single = try? decoder.singleValueContainer(),
                    let text = try? single.decode(String.self)
                {
                    message = text
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try container.decodeIfPresent(String.self, forKey: .message)
            }

            private enum CodingKeys: String, CodingKey { case message }
        }
        /// Optional because an error envelope may carry only `error`.
        let type: String?
        let delta: String?
        let text: String?
        let error: Failure?
    }

    /// Why a streaming attempt should be retried without `stream=true`.
    ///
    /// Only these two mean "this provider or model cannot stream". Every other
    /// failure is left alone, because retrying an upload the provider may
    /// already have transcribed bills the user twice.
    enum StreamingUnsupported: Error {
        case notAStream
        case server(TranscriptionError)
    }

    /// Assembles server-sent events from a line stream.
    ///
    /// A single event can span several `data:` lines, which the spec says to
    /// join with newlines; decoding each line on its own drops any JSON that
    /// happens to be split. Events are terminated by a blank line.
    struct SSEParser {
        struct Event {
            var name: String?
            var data: String
        }

        private var name: String?
        private var dataLines: [String] = []

        /// Feeds one line in, returning an event when the line completes one.
        mutating func consume(_ line: String) -> Event? {
            if line.isEmpty { return flush() }
            // A line starting with a colon is a comment, commonly used as a
            // keep-alive.
            if line.hasPrefix(":") { return nil }
            if let value = Self.value(of: "event", in: line) {
                name = value
            } else if let value = Self.value(of: "data", in: line) {
                dataLines.append(value)
            }
            return nil
        }

        /// Emits whatever has been gathered, for a stream that ended without a
        /// closing blank line.
        mutating func flush() -> Event? {
            defer { name = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return Event(name: name, data: dataLines.joined(separator: "\n"))
        }

        /// Reads one SSE field, stripping the single optional leading space.
        private static func value(of field: String, in line: String) -> String? {
            // The spec treats a line that is only the field name as that field
            // with an empty value, so `data` alone still forms an event.
            if line == field { return "" }
            guard line.hasPrefix(field + ":") else { return nil }
            var value = String(line.dropFirst(field.count + 1))
            if value.hasPrefix(" ") { value.removeFirst() }
            return value
        }
    }

    static func transcriptionEndpoint(for baseURL: String) throws -> URL {
        var components = try ProviderNetworking.validatedComponents(for: baseURL)

        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/audio/transcriptions") {
            path += "/audio/transcriptions"
        }
        components.path = path
        guard let endpoint = components.url else {
            throw TranscriptionError.invalidConfiguration("The provider URL could not be constructed.")
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

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}
