import SwiftUI

/// Shared by setup and Settings. Only models supported by both Google's live
/// catalog and MicMyDay's audio transport can enter the picker.
struct GeminiConnectSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var models: [GeminiModelCatalog.Model] = []
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var task: Task<Void, Never>?

    private var trimmedKey: String {
        settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Gemini API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                RevealableSecureField(placeholder: "AIza…", text: $settings.geminiAPIKey)
                    .onSubmit { refresh() }
                Text("Rewriting uses a separate key, set in Settings → Rewrite.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Link("Get a Gemini API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.system(size: 11))
                Text("Your key is stored in Keychain. Recordings are sent to Google; API usage may be billed separately from a Gemini subscription.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }

            HStack(spacing: 10) {
                Button(loading ? "Checking models…" : (models.isEmpty ? "Use key" : "Refresh models")) { refresh() }
                    .buttonStyle(.beacon)
                    .disabled(trimmedKey.isEmpty || loading)
                if !trimmedKey.isEmpty {
                    Button("Remove key") { settings.geminiAPIKey = "" }
                        .buttonStyle(.beaconQuiet)
                }
            }

            if let error {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mfWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Transcription model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                    Picker("", selection: $settings.geminiModel) {
                        ForEach(models) { model in Text(model.title).tag(model.id) }
                    }
                    .dsMenuPicker(width: 280, alignment: .leading)
                    Text("Choose a model to transcribe your recordings.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    if settings.geminiModel == GeminiModelCatalog.defaultModelID {
                        Text("Optional rewriting is applied after transcription.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    }
                }
            }
        }
        .onAppear { if !trimmedKey.isEmpty { refresh() } }
        .onChange(of: settings.geminiAPIKey) { _, _ in
            cancel()
            models = []
            error = nil
        }
        .onDisappear { cancel() }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        loading = false
    }

    private func refresh() {
        cancel()
        guard !trimmedKey.isEmpty else { return }
        let key = trimmedKey
        let id = requestID
        loading = true
        error = nil
        task = Task { @MainActor in
            do {
                let fetched = try await GeminiModelCatalog.fetchModels(apiKey: key)
                guard !Task.isCancelled, requestID == id, trimmedKey == key else { return }
                models = fetched
                // Only move the selection when the fetch actually offered
                // something. Clearing it on an empty result stranded the user:
                // the picker hides itself when the list is empty, so there was
                // no control left to choose a model with, and onboarding could
                // never be satisfied even with a valid key.
                if !fetched.isEmpty, !fetched.contains(where: { $0.id == settings.geminiModel }) {
                    settings.geminiModel = fetched[0].id
                }
                if fetched.isEmpty {
                    error = "Google returned no transcription models supported by this version of MicMyDay. Refresh later or check for an app update."
                }
            } catch {
                guard !Task.isCancelled, requestID == id, trimmedKey == key else { return }
                models = []
                self.error = "Could not load Gemini models: \(error.localizedDescription)"
            }
            loading = false
            task = nil
        }
    }
}
