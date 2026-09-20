import SwiftUI

/// 04 Setup — whatever the chosen engine needs, and nothing else. The heading
/// and the rail label both follow the engine.
struct SetupChapter: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChapterHeading(title: heading, lede: lede)

            switch settings.provider {
            case .whisper, .parakeet, .nemotron: WhisperModelPicker()
            case .openAI: OpenAIConnectSection()
            case .gemini: GeminiConnectSection()
            case .custom: CustomEndpointSection()
            case .appleSpeech: AppleSpeechOptionsSection()
            }
        }
    }

    private var heading: String {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron: return "Choose a transcription model"
        case .openAI, .gemini: return "Connect \(settings.provider.title)"
        case .custom: return "Connect your server"
        case .appleSpeech: return "Set up Apple Speech"
        }
    }

    private var lede: String {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron:
            return "Download a model to transcribe privately on your Mac, even offline."
        case .openAI, .gemini:
            return "Paste an API key from your chosen provider. It is stored securely in your Mac's Keychain."
        case .custom:
            return "Connect a server that supports the OpenAI transcription API."
        case .appleSpeech:
            return "Choose whether Apple Speech must transcribe on your Mac or can use Apple’s cloud."
        }
    }
}

// MARK: - Local models

struct WhisperModelPicker: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = WhisperModelManager.shared
    @State private var showAll = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showAll {
                filterField
                counter
            }

            if showAll {
                VStack(spacing: 0) {
                    ForEach(filtered) { model in
                        BeaconModelRow(model: model, selected: settings.whisperModelID == model.id)
                    }
                    if filtered.isEmpty {
                        Text("No model matches \u{201C}\(query)\u{201D}.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(engineRecommended) { model in
                        BeaconModelRow(model: model, selected: settings.whisperModelID == model.id)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
            }

            if let error = manager.lastError {
                StatusLabel(text: error, tone: .warn, symbol: "exclamationmark.triangle")
            } else if manager.loadingModelID == settings.whisperModelID {
                StatusLabel(
                    text: "Loading the transcription model…",
                    tone: .neutral,
                    symbol: "hourglass"
                )
            }

            Button(showAll ? "Show recommended only" : "Show all \(engineModels.count) models") {
                showAll.toggle()
                query = ""
            }
            .buttonStyle(.beaconPlain)
        }
    }

    private var filterField: some View {
        TextField("Search models", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
    }

    private var counter: some View {
        Text("\(filtered.count) of \(engineModels.count) \u{00B7} \(manager.installedModelIDs.count) installed")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
    }

    /// Only the chosen engine's models. Whisper's nine, Parakeet's two and
    /// Nemotron's three used to be one list of fourteen, which is the length
    /// that made the section feel like a catalogue to wade through rather
    /// than a choice to make.
    private var engineModels: [WhisperModel] {
        guard let engine = settings.provider.localEngine else { return WhisperModelCatalog.models }
        return WhisperModelCatalog.models.filter { $0.engine == engine }
    }

    private var engineRecommended: [WhisperModel] {
        let recommended = engineModels.filter(\.isRecommended)
        // An engine whose models are all worth showing, or none marked, shows
        // them all rather than nothing.
        return recommended.isEmpty ? engineModels : recommended
    }

    private var filtered: [WhisperModel] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return engineModels }
        return engineModels.filter {
            $0.displayName.lowercased().contains(trimmed)
                || $0.note.lowercased().contains(trimmed)
                || "\($0.approximateSizeMB) mb".contains(trimmed)
        }
    }
}

private struct BeaconModelRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = WhisperModelManager.shared
    let model: WhisperModel
    let selected: Bool

    var body: some View {
        // Selecting only. Downloading used to happen on the same tap, which
        // meant choosing a model to read about it immediately committed to
        // several hundred megabytes; the download is now its own control.
        Button {
            settings.whisperModelID = model.id
        } label: {
            HStack(spacing: 12) {
                // The tick sits on the name's own line rather than in the
                // middle of the row. Centred, it drifted lower the longer the
                // note underneath grew, until on a three-line row it pointed
                // at the description instead of the thing it marks.
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ZStack {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.mfAccent)
                        }
                    }
                    .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(Color.mfTextPrimary)
                        if !model.note.isEmpty {
                            Text(model.note)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 12) {
                            modelRating("Speed", value: assessment.speed)
                            modelRating("Accuracy", value: assessment.accuracy)
                        }
                        .padding(.top, 3)
                        .help(EngineCatalog.ratingsHelp)
                    }
                }

                Spacer(minLength: 8)

                trailing
            }
            .padding(.horizontal, 16)
            // Padding rather than a fixed height: a note long enough to wrap
            // was being drawn into a row sized for one line of it.
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.displayName)
        .accessibilityValue(
            [model.note, "Estimated speed \(assessment.speed) out of 4, accuracy \(assessment.accuracy) out of 4",
             installed ? "Installed" : "\(model.approximateSizeMB) megabytes to download"]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // The cancel control has to be a sibling layer, not a button nested in
        // the row button's label — nested buttons never receive the click, so
        // cancelling silently did nothing.
        .overlay(alignment: .trailing) {
            if downloading {
                Button {
                    manager.cancelDownload(model.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Cancel download")
                .padding(.trailing, 11)
            } else if !installed {
                Button {
                    manager.download(model)
                } label: {
                    Text("Get \(model.approximateSizeMB) MB")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.mfAccent)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Download this model (\(model.approximateSizeMB) MB)")
                .padding(.trailing, 8)
            } else if deletable {
                Button {
                    manager.delete(model.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Delete the downloaded model (\(model.approximateSizeMB) MB)")
                .padding(.trailing, 11)
            }
        }
    }

    private var assessment: TranscriptionAssessment {
        let provider: TranscriptionProviderKind
        switch model.engine {
        case .whisper: provider = .whisper
        case .parakeet: provider = .parakeet
        case .nemotron: provider = .nemotron
        }
        return EngineCatalog.assessment(for: provider, modelID: model.id)
    }

    private func modelRating(_ label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            if value == 0 {
                Text("—").font(.system(size: 10))
            } else {
                ForEach(1...4, id: \.self) { step in
                    Circle()
                        .fill(step <= value ? Color.mfAccent : Color.mfFill(0.12))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }

    private var installed: Bool { manager.installedModelIDs.contains(model.id) }
    private var downloading: Bool { manager.downloadProgress[model.id] != nil }

    /// The selected model stays deletable on purpose: a truncated or corrupt
    /// download refuses to load, and `download` refuses to run while the file
    /// exists, so hiding delete here left no way to repair it from inside the
    /// app. Only an in-flight load blocks deletion.
    private var deletable: Bool {
        installed && !downloading && manager.loadingModelID != model.id
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress = manager.downloadProgress[model.id] {
            // Trailing room left for the cancel control, which is overlaid.
            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfAccent)
                .padding(.trailing, 20)
        } else if manager.loadingModelID == model.id {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Color.mfAccent)
        } else if manager.readyModelID == model.id {
            // Trailing room left for the delete control on unselected rows.
            Text("Ready")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfReady)
                .padding(.trailing, deletable ? 20 : 0)
        } else if installed {
            // Trailing room left for the delete control, which is overlaid.
            Text("\(model.approximateSizeMB) MB")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                .padding(.trailing, deletable ? 20 : 0)
        } else {
            // Space for the Get control, which is overlaid.
            Text("\(model.approximateSizeMB) MB")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.clear)
                .padding(.trailing, 20)
        }
    }
}

// MARK: - OpenAI

/// Cloud transcription uses the selected provider's API account.
struct OpenAIConnectSection: View {
    @EnvironmentObject private var settings: SettingsStore

    private enum Validation: Equatable {
        case idle
        case validating
        case failed(String)
        case validated([String])
    }

    @State private var validation: Validation = .idle

    private var apiKey: Binding<String> { $settings.openAIApiKey }

    private var model: Binding<String> { $settings.openAIModel }

    private var baseURL: String {
        settings.provider.transcriptionBaseURL ?? ""
    }

    private var defaultModel: String {
        settings.provider.defaultTranscriptionModel ?? ""
    }

    private var trimmedKey: String {
        apiKey.wrappedValue.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(settings.provider.title) API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                RevealableSecureField(placeholder: "API key", text: apiKey)
                    .onSubmit { validate() }
                Text("Your provider may charge separately for API usage. A ChatGPT subscription does not include OpenAI API credits.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            }

            HStack(spacing: 10) {
                Button(validation == .validating ? "Checking key\u{2026}" : "Use key") {
                    validate()
                }
                .buttonStyle(.beacon)
                .disabled(trimmedKey.isEmpty || validation == .validating)

                if !trimmedKey.isEmpty {
                    Button("Remove key") {
                        apiKey.wrappedValue = ""
                        validation = .idle
                    }
                    .buttonStyle(.beaconQuiet)
                }
            }

            switch validation {
            case .idle, .validating:
                EmptyView()
            case .failed(let message):
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.mfWarn)
            case .validated(let models):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mfReady)
                        Text("Key verified \u{00B7} \(models.count) transcription models available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                        Picker("", selection: model) {
                            ForEach(models, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                        .dsMenuPicker(width: 260, alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: settings.provider) { _, _ in validation = .idle }
        .onChange(of: apiKey.wrappedValue) { _, _ in
            if validation != .idle, validation != .validating { validation = .idle }
        }
    }

    private func validate() {
        guard !trimmedKey.isEmpty else { return }
        validation = .validating
        let key = trimmedKey
        let url = baseURL
        // Switching provider or editing the key while a request is in flight
        // must not let the old answer land: it would otherwise write one
        // provider's model into another's setting and break dictation.
        let requestedProvider = settings.provider
        Task {
            do {
                let ids = try await ProviderModelCatalog.fetchModelIDs(baseURL: url, apiKey: key)
                guard settings.provider == requestedProvider, trimmedKey == key else { return }
                let models = ProviderModelCatalog.transcriptionModels(in: ids)
                guard !models.isEmpty else {
                    validation = .failed("Key verified, but no compatible models were found.")
                    return
                }
                // Keep an earlier choice while the provider still offers it;
                // otherwise fall back to the default for this provider.
                if !models.contains(model.wrappedValue) {
                    model.wrappedValue = models.contains(defaultModel) ? defaultModel : (models.first ?? "")
                }
                validation = .validated(models)
            } catch {
                guard settings.provider == requestedProvider, trimmedKey == key else { return }
                validation = .failed("Couldn’t connect: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Custom endpoint

struct CustomEndpointSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabelledField(label: "Base URL") {
                TextField("http://127.0.0.1:8000/v1", text: $settings.customBaseURL)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("API token")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                RevealableSecureField(placeholder: "Optional", text: $settings.customAPIToken)
                Text("Sent as a Bearer token when your server needs one.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            }
            CustomModelField(
                baseURL: settings.customBaseURL,
                apiKey: settings.customAPIToken,
                placeholder: "whisper-1",
                model: $settings.customModel,
                manualEntry: $settings.customModelManualEntry
            )
            Text("MicMyDay posts to /audio/transcriptions on this base URL.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
        }
    }
}

/// Model selection for a self-hosted endpoint: either a dropdown filled from
/// the server's /models (the default; Ollama, vLLM, and most OpenAI-compatible
/// servers implement it) or a typed model id. One control at a time, and the
/// choice is remembered.
struct CustomModelField: View {
    let baseURL: String
    var apiKey: String = ""
    var headers: [CustomHeader] = []
    let placeholder: String
    @Binding var model: String
    @Binding var manualEntry: Bool

    private enum Load: Equatable {
        case loading
        case failed(String)
        case loaded([String])
    }

    @State private var load: Load = .loading
    @State private var fetchAttempt = 0

    private var trimmedBase: String {
        baseURL.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manualEntry {
                LabelledField(label: "Model") {
                    TextField(placeholder, text: $model)
                }
                Button("Choose from available models") { manualEntry = false }
                    .buttonStyle(.beaconPlain)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                    if trimmedBase.isEmpty {
                        Text("Enter the Base URL first.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
                    } else {
                        switch load {
                        case .loading:
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Loading models…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
                            }
                        case .failed(let message):
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                                Text(message)
                                    .font(.system(size: 11, weight: .medium))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(Color.mfWarn)
                            Button("Try again") { fetchAttempt += 1 }
                                .buttonStyle(.beaconQuiet)
                        case .loaded(let models):
                            Picker("", selection: selection(models)) {
                                ForEach(models, id: \.self) { id in
                                    Text(id).tag(id)
                                }
                            }
                            .dsMenuPicker(width: 260, alignment: .leading)
                        }
                    }
                }
                Button("Enter a model ID") { manualEntry = true }
                    .buttonStyle(.beaconPlain)
            }
        }
        // Auto-fetch whenever the dropdown mode is active and the inputs
        // change; the short sleep debounces typing in the Base URL field.
        .task(id: "\(manualEntry)|\(trimmedBase)|\(apiKey)|\(fetchAttempt)") {
            guard !manualEntry, !trimmedBase.isEmpty else { return }
            load = .loading
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await fetch()
        }
    }

    private func selection(_ models: [String]) -> Binding<String> {
        Binding(
            get: { models.contains(model) ? model : (models.first ?? "") },
            set: { model = $0 }
        )
    }

    private func fetch() async {
        do {
            let ids = try await ProviderModelCatalog.fetchModelIDs(baseURL: trimmedBase, apiKey: apiKey, headers: headers)
            guard !ids.isEmpty else {
                load = .failed("No models were found. Enter a model ID manually.")
                return
            }
            // The dropdown is the source of truth in this mode; make sure the
            // stored model is something the server actually offers.
            if !ids.contains(model) { model = ids.first ?? model }
            load = .loaded(ids)
        } catch {
            load = .failed("Could not list models: \(error.localizedDescription)")
        }
    }
}

struct AppleSpeechOptionsSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        BeaconCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $settings.preferOnDevice) {
                    Text("Transcribe on this Mac only")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .tint(.mfAccent)

                if !settings.preferOnDevice {
                    StatusLabel(
                        text: "With “Transcribe on this Mac only” turned off, audio may be sent to Apple’s cloud for transcription. No language download is needed.",
                        tone: .warn,
                        symbol: "exclamationmark.triangle.fill"
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.statusWarnText.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

// MARK: - Shared field chrome

struct LabelledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
            field
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
        }
    }
}

/// A secure field with a reveal toggle, as the design specifies for every
/// credential input.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.mfTextPrimary)

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))
    }
}
