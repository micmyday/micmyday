import SwiftUI

/// 06 Rewrite — the optional LLM pass, its provider, and the named prompt
/// profiles. Off by default: nothing should sit between the microphone and the
/// cursor unless the user asks for it.
struct RewriteChapter: View {
    @EnvironmentObject private var settings: SettingsStore
    /// "Change" reopens the picker explicitly rather than clearing the
    /// credential, so switching providers never destroys a working key.
    @State private var pickerOpen = false
    /// Set when the pane opens on an already-configured provider, and when
    /// the user presses the confirm button. Without it, typing the first
    /// character of a model id collapsed the editor and persisted a partial
    /// value, because the readiness check flips as soon as the fields are
    /// non-empty.
    @State private var confirmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ChapterHeading(
                title: SettingsPane.rewrite.title,
                lede: SettingsPane.rewrite.lede
            )

            BeaconCard {
                Toggle(isOn: $settings.enhancementEnabled) {
                    Text("Rewrite transcripts before inserting")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mfTextPrimary)
                }
                .toggleStyle(.switch)
                .tint(.mfAccent)
            }

            if settings.enhancementEnabled {
                if confirmed && connected && !pickerOpen {
                    RewriteConnectedRow { pickerOpen = true }
                        .onAppear { if connected { confirmed = true } }
                    localModelPicker
                } else {
                    RewriteProviderPicker(onConnected: { confirmed = true; pickerOpen = false })
                        .onAppear { if connected { confirmed = true } }
                    localModelPicker
                }
            } else {
                RewriteOffComparison()
            }
        }
    }

    /// Only "On this Mac" has a model to choose.
    @ViewBuilder
    private var localModelPicker: some View {
        if settings.rewriteProvider == .onDevice {
            VStack(alignment: .leading, spacing: 10) {
                SectionEyebrow(text: "MODEL")
                LocalRewriteModelPicker()
            }
        }
    }

    private var connected: Bool {
        settings.rewriteProviderIsConfigured
    }
}

// MARK: - Off

/// Both columns show the same sentence. That is the point: nothing is altered.
struct RewriteOffComparison: View {
    // Spoken and rewritten, not the same sentence twice: printing one string in
    // both columns showed the reader nothing, since with rewriting off there is
    // by definition no difference to see. What is worth showing is what turning
    // it on would do, so the columns are a real before and after.
    private let spoken = "um so refactor the auth module to use the new session store, no wait, keep the old API as a deprecated shim, and uh add tests for the token refresh path"
    private let rewritten = "Refactor the auth module to use the new session store, keep the old API as a deprecated shim, and add tests for the token refresh path."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                column(label: "YOU SAID", text: spoken)
                column(label: "WITH REWRITING ON", text: rewritten)
            }
            Text("Use rewriting to clean up a transcript or turn it into a message, email or AI prompt using a profile’s instructions.")
                .font(.system(size: 11))
                .lineSpacing(3)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
    }
}

// MARK: - Provider

struct RewriteProviderPicker: View {
    @EnvironmentObject private var settings: SettingsStore
    /// Called when the chosen provider is already usable, so the picker can
    /// collapse back to the one-line confirmation.
    var onConnected: () -> Void = {}
    /// Off when a SettingsCard already provides the same eyebrow.
    var showsEyebrow = true

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsEyebrow {
                SectionEyebrow(text: "REWRITE ENGINE")
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(RewriteProviderKind.offered) { provider in
                    providerPill(provider)
                }
            }

            credentials

            if let message = blockedMessage {
                RewriteSetupWarning(
                    headline: message,
                    detail: "Transcripts will be inserted without rewriting until setup is complete."
                )
            }
        }
    }

    private func providerPill(_ provider: RewriteProviderKind) -> some View {
        Button {
            settings.rewriteProvider = provider
            if isUsable(provider) { onConnected() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(settings.rewriteProvider == provider ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if settings.rewriteProvider == provider {
                        Circle().fill(Color.mfAccent).frame(width: 7, height: 7)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary)
                    Text(provider.note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                settings.rewriteProvider == provider ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.title)
        .accessibilityValue(provider.note)
        .accessibilityAddTraits(settings.rewriteProvider == provider ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var credentials: some View {
        switch settings.rewriteProvider.requirement {
        case .none:
            // Nothing to fill in. Either macOS can run its own model or it
            // cannot, and the state above already says which.
            EmptyView()
        case .key:
            KeyedProviderCredentials(onConnected: onConnected)
        case .url:
            VStack(alignment: .leading, spacing: 12) {
                LabelledField(label: "Base URL") {
                    TextField("http://127.0.0.1:11434/v1", text: $settings.enhancementBaseURL)
                }
                RewriteHeadersSection()
                CustomModelField(
                    baseURL: settings.enhancementBaseURL,
                    headers: settings.rewriteCustomHeaders,
                    placeholder: "llama3.1:8b",
                    model: $settings.enhancementModel,
                    manualEntry: $settings.rewriteModelManualEntry
                )
                Button("Use this endpoint", action: onConnected)
                    .buttonStyle(.beacon)
                    .disabled(settings.enhancementBaseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    /// Only meaningful for the provider currently selected, which is the only
    /// one whose credentials and model are loaded.
    private func isUsable(_ provider: RewriteProviderKind) -> Bool {
        provider == settings.rewriteProvider && settings.rewriteProviderIsConfigured
    }

    private var blockedMessage: String? {
        guard !isUsable(settings.rewriteProvider) else { return nil }
        switch settings.rewriteProvider {
        case .onDevice:
            // Local availability belongs beside the selected model.
            return nil
        case .anthropic: return "Add your Anthropic API key and pick a model to turn rewriting on."
        case .gemini: return "Add your Gemini API key and pick a model to turn rewriting on."
        case .openai: return "Add your OpenAI API key and pick a model to turn rewriting on."
        case .custom: return "Enter your server URL and pick a model to turn rewriting on."
        }
    }
}

private struct RewriteSetupWarning: View {
    let headline: String
    let detail: String
    var showsOnDeviceGuide = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 11)).opacity(0.8)
                if showsOnDeviceGuide {
                    Link("How to set this up", destination: URL(string: "https://micmyday.com/documentation/on-device-rewriting/")!)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .underline()
                        .padding(.top, 2)
                }
            }
        }
        .foregroundStyle(Color.mfWarn)
    }
}

/// Key entry for the hosted providers (OpenAI, Gemini): the key is verified
/// against the provider's /models endpoint before it is accepted, and the
/// same response fills the model dropdown.
private struct KeyedProviderCredentials: View {
    @EnvironmentObject private var settings: SettingsStore
    let onConnected: () -> Void

    private enum Validation: Equatable {
        case idle
        case validating
        case failed(String)
        case validated([String])
    }

    @State private var validation: Validation = .idle

    /// The key a request would actually use. enhancementConfiguration() falls
    /// back to the transcription key for OpenAI, so without the same fallback
    /// here the "Use key" button stayed disabled and no model could ever be
    /// picked, leaving rewriting permanently unconfigured.
    private var trimmedKey: String {
        let own = settings.enhancementAPIKey.trimmingCharacters(in: .whitespaces)
        if own.isEmpty, settings.rewriteProvider == .openai {
            return settings.openAIApiKey.trimmingCharacters(in: .whitespaces)
        }
        return own
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(settings.rewriteProvider.keyLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                RevealableSecureField(
                    placeholder: settings.rewriteProvider.keyPlaceholder,
                    text: $settings.enhancementAPIKey
                )
                .onSubmit { validate() }
                Text(settings.rewriteProvider.keyHint)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(validation == .validating ? "Checking key\u{2026}" : "Use key") {
                    validate()
                }
                .buttonStyle(.beacon)
                .disabled(trimmedKey.isEmpty || validation == .validating)

                if !trimmedKey.isEmpty {
                    Button("Remove key") {
                        settings.enhancementAPIKey = ""
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
                        Text("Key verified \u{00B7} \(models.count) models available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                        Picker("", selection: modelSelection(models)) {
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .dsMenuPicker(width: 260, alignment: .leading)
                    }
                    Button("Use this model", action: onConnected)
                        .buttonStyle(.beacon)
                }
            }
        }
        .onChange(of: settings.rewriteProvider) { _, _ in validation = .idle }
        .onChange(of: settings.enhancementAPIKey) { _, _ in
            if case .validated = validation { validation = .idle }
            if case .failed = validation { validation = .idle }
        }
    }

    /// Binds the dropdown to the stored per-provider model.
    private func modelSelection(_ models: [String]) -> Binding<String> {
        let provider = settings.rewriteProvider
        return Binding(
            get: {
                if let chosen = settings.rewriteProviderModels[provider.rawValue] { return chosen }
                if let wanted = provider.defaultModel,
                   let preferred = models.first(where: { $0 == wanted || $0.hasSuffix("/" + wanted) }) {
                    return preferred
                }
                return models.first ?? ""
            },
            set: { settings.rewriteProviderModels[provider.rawValue] = $0 }
        )
    }

    private func validate() {
        let provider = settings.rewriteProvider
        guard let baseURL = provider.apiBaseURL, !trimmedKey.isEmpty else { return }
        validation = .validating
        let key = trimmedKey
        Task {
            do {
                let ids = try await ProviderModelCatalog.fetchModelIDs(baseURL: baseURL, apiKey: key)
                let models = ProviderModelCatalog.chatModels(in: ids)
                guard !models.isEmpty else {
                    validation = .failed("Key verified, but no compatible models were found.")
                    return
                }
                // A model the user picked earlier stays selected as long as
                // the provider still offers it. Otherwise fall back to the
                // default (gpt-5.6-luna on OpenAI), so a stale choice never
                // lingers after a key change.
                let stored = settings.rewriteProviderModels[provider.rawValue]
                if stored == nil || !models.contains(stored ?? "") {
                    // Match by suffix: Google's OpenAI-compatible listing
                    // returns "models/gemini-2.5-flash", so an exact compare
                    // against the bare default never hit and the preselection
                    // fell through to whatever sorted first.
                    let preferred = provider.defaultModel.flatMap { wanted in
                        models.first { $0 == wanted || $0.hasSuffix("/" + wanted) }
                    }
                    settings.rewriteProviderModels[provider.rawValue] = preferred ?? models.first
                }
                validation = .validated(models)
            } catch {
                validation = .failed("Couldn’t connect: \(error.localizedDescription)")
            }
        }
    }
}

/// Repeatable name/value headers for a self-hosted endpoint.
struct RewriteHeadersSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "HEADERS")
            Text("Add authentication or other headers required by your server.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))

            ForEach($settings.rewriteCustomHeaders) { $header in
                HStack(spacing: 8) {
                    TextField("Authorization", text: $header.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(width: 170)

                    RevealableSecureField(placeholder: "Bearer sk-\u{2026}", text: $header.value)

                    Button {
                        settings.rewriteCustomHeaders.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                settings.rewriteCustomHeaders.append(CustomHeader())
            } label: {
                Label("Add header", systemImage: "plus")
            }
            .buttonStyle(.beaconQuiet)
        }
    }
}

// MARK: - Connected

struct RewriteConnectedRow: View {
    @EnvironmentObject private var settings: SettingsStore
    let change: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.mfReady)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.rewriteProvider.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mfTextPrimary)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }
            Spacer(minLength: 0)
            Button("Change", action: change)
                .buttonStyle(.beaconQuiet)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
    }

    private var detail: String {
        switch settings.rewriteProvider {
        case .onDevice:
            return "Private rewriting on this Mac"
        case .anthropic, .gemini, .openai:
            let model = settings.rewriteModel(for: settings.rewriteProvider) ?? "model"
            return "\(model) \u{00B7} using your key"
        case .custom:
            let model = settings.enhancementModel.isEmpty ? "model" : settings.enhancementModel
            return "\(model) \u{00B7} \(settings.enhancementBaseURL)"
        }
    }

}

// MARK: - Profiles

struct RewriteProfilesSection: View {
    @EnvironmentObject private var settings: SettingsStore
    /// Off when a SettingsCard already supplies the same eyebrow.
    var showsEyebrow = true

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if showsEyebrow { SectionEyebrow(text: "PROFILES") }
                Text("Choose how each transcript is rewritten.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                Spacer()
                Button {
                    addProfile()
                } label: {
                    Label("New profile", systemImage: "plus")
                }
                .buttonStyle(.beaconQuiet)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(settings.rewriteProfiles) { profile in
                    profilePill(profile)
                }
            }

            editor
        }
    }

    private func profilePill(_ profile: RewriteProfile) -> some View {
        Button {
            settings.rewriteProfileID = profile.id
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(selected(profile) ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if selected(profile) {
                        Circle().fill(Color.mfAccent).frame(width: 7, height: 7)
                    }
                }
                Image(systemName: settings.icon(forProfile: profile.id).symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(selected(profile) ? Color.mfAccent : Color.mfTextPrimary.opacity(0.5))
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary)
                    .lineLimit(1)
                if !profile.builtin {
                    Text("YOURS")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.mfAccent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                selected(profile) ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selected(_ profile: RewriteProfile) -> Bool {
        settings.rewriteProfileID == profile.id
    }

    @ViewBuilder
    private var editor: some View {
        let id = settings.rewriteProfileID
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(currentProfile?.name.uppercased() ?? "PROMPT")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.mfAccent)
                Spacer()
                if settings.promptWasEdited(id) {
                    Button("Reset to default") {
                        settings.rewritePrompts[id] = nil
                    }
                    .buttonStyle(.beaconPlain)
                }
                if currentProfile?.builtin == false {
                    Button("Delete profile") { deleteProfile() }
                        .buttonStyle(.beaconPlain)
                }
            }

            if currentProfile?.builtin == false {
                TextField("Profile name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let profile = currentProfile {
                ProfileIconPicker(profileID: profile.id, profileName: profile.name)
                    .padding(.bottom, 2)
            }

            TextEditor(text: promptBinding)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 132)
                .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: MFMetric.radiusControl, style: .continuous))

            Text("These instructions guide rewrites with this profile. Rewriting uses transcript text, not audio.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
        }
    }

    private var currentProfile: RewriteProfile? {
        settings.currentRewriteProfile
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { settings.prompt(for: settings.rewriteProfileID) },
            set: { settings.rewritePrompts[settings.rewriteProfileID] = $0 }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { currentProfile?.name ?? "" },
            set: { newValue in
                guard let index = settings.rewriteProfiles.firstIndex(where: { $0.id == settings.rewriteProfileID }) else { return }
                settings.rewriteProfiles[index].name = newValue
            }
        )
    }

    private func addProfile() {
        let id = "custom-\(UUID().uuidString.prefix(8))"
        let profile = RewriteProfile(id: id, name: "Profile \(settings.rewriteProfiles.count + 1)", builtin: false)
        settings.rewriteProfiles.append(profile)
        settings.rewritePrompts[id] = RewriteProfile.defaultPrompt(for: id)
        settings.rewriteProfileID = id
    }

    private func deleteProfile() {
        let id = settings.rewriteProfileID
        settings.rewriteProfiles.removeAll { $0.id == id }
        settings.rewritePrompts[id] = nil
        settings.profileShortcuts[id] = nil
        settings.profileIcons[id] = nil
        // The fallback must be a profile that still exists, or
        // enhancementConfiguration() silently returns nil and rewriting stops.
        // Builtins are never deletable, so `last` is always available.
        settings.rewriteProfileID = settings.rewriteProfiles.last?.id ?? "cleanup"
    }
}

/// The mono eyebrow used to open a section.
struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.6)
            .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
    }
}

// MARK: - Models that run on this Mac

/// The model list shown when the provider is "On this Mac".
///
/// Apple's built-in model and the downloadable ones share one list because
/// that is the choice as the user has it: which model on this Mac tidies my
/// words. The only difference between the rows is that one of them is already
/// here, which the row says for itself.
struct LocalRewriteModelPicker: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = RewriteModelManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            availabilityWarning

            VStack(spacing: 0) {
                ForEach(RewriteModelCatalog.models) { model in
                    LocalRewriteModelRow(model: model, selected: settings.localRewriteModelID == model.id)
                }
            }
            .padding(.vertical, 4)
            .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))

            if let error = manager.lastError {
                StatusLabel(text: error, tone: .warn, symbol: "exclamationmark.triangle")
            } else if manager.loadingModelID == settings.localRewriteModelID {
                StatusLabel(
                    text: "Loading the model for rewriting…",
                    tone: .neutral,
                    symbol: "hourglass"
                )
            }
        }
    }

    /// Keep local-model requirements at the top of Model, including when the
    /// engine picker has collapsed to its connected row.
    @ViewBuilder
    private var availabilityWarning: some View {
        if settings.rewriteProvider == .onDevice {
            if !settings.rewriteProviderIsConfigured, let reason = settings.rewriteUnavailableReason {
                RewriteSetupWarning(
                    headline: reason,
                    detail: "Transcripts will be inserted without rewriting until setup is complete.",
                    showsOnDeviceGuide: appleModelSelected
                )
            } else if let unsupported = unsupportedLanguageName {
                RewriteSetupWarning(
                    headline: "Apple’s built-in model does not support \(unsupported).",
                    detail: "Choose another model or provider to rewrite in this language.",
                    showsOnDeviceGuide: true
                )
            }
        }
    }

    private var appleModelSelected: Bool {
        RewriteModelCatalog.model(withID: settings.localRewriteModelID)?.isAppleBuiltIn == true
    }

    private var unsupportedLanguageName: String? {
        guard appleModelSelected,
              AppleOnDeviceRewriter.supportsLanguage(settings.selectedLanguage.id) == false else {
            return nil
        }
        return settings.selectedLanguage.name
    }
}

private struct LocalRewriteModelRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var manager = RewriteModelManager.shared
    let model: LocalRewriteModel
    let selected: Bool

    var body: some View {
        // Selecting only. Downloading is its own control, so reading about a
        // model never commits the user to gigabytes.
        Button {
            settings.localRewriteModelID = model.id
        } label: {
            HStack(spacing: 12) {
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
                        HStack(spacing: 8) {
                            Text(model.displayName)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(Color.mfTextPrimary)
                            if model.isRecommended {
                                Text("Recommended")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color.mfAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.mfAccent.opacity(0.1), in: Capsule())
                            }
                        }
                        Text(model.note)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            modelRating("Speed", value: model.speed)
                            modelRating("Quality", value: model.quality)
                        }
                        .padding(.top, 3)
                        .help(model.isAppleBuiltIn
                              ? "Apple’s built-in model has not been rated for rewriting yet."
                              : RewriteModelCatalog.ratingsHelp)
                    }
                }

                Spacer(minLength: 8)

                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.displayName)
        .accessibilityValue([model.note, accessibilityRatings, accessibilityState].joined(separator: ". "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // A sibling layer rather than a button nested inside the row button's
        // label: a nested button never receives the click, so cancelling and
        // deleting would silently do nothing.
        .overlay(alignment: .trailing) { control }
    }

    /// The right-hand side of the row before any control: what this model costs.
    @ViewBuilder
    private var trailing: some View {
        if let progress = manager.downloadProgress[model.id] {
            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                .padding(.trailing, 22)
        } else if model.isAppleBuiltIn || installed {
            Text(model.isAppleBuiltIn ? "Built into macOS" : "Installed")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                .padding(.trailing, installed ? 22 : 0)
        } else {
            Text("Get \(model.sizeLabel)")
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .hidden()
        }
    }

    private func modelRating(_ label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            if value == 0 {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            } else {
                ForEach(1...4, id: \.self) { step in
                    Circle()
                        .fill(step <= value ? Color.mfAccent : Color.mfFill(0.12))
                        .frame(width: 4, height: 4)
                }
            }
        }
    }

    private var accessibilityRatings: String {
        let speed = model.speed == 0 ? "Speed unrated" : "Speed \(model.speed) of 4"
        let quality = model.quality == 0 ? "Quality unrated" : "Quality \(model.quality) of 4"
        return (model.isRecommended ? ["Recommended", speed, quality] : [speed, quality])
            .joined(separator: ". ")
    }

    @ViewBuilder
    private var control: some View {
        if manager.downloadProgress[model.id] != nil {
            Button { manager.cancelDownload(model.id) } label: {
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
        } else if model.isAppleBuiltIn {
            EmptyView()
        } else if !installed {
            Button { manager.download(model) } label: {
                Text("Get \(model.sizeLabel)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.mfAccent)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Download this model (\(model.sizeLabel))")
            .padding(.trailing, 8)
        } else {
            Button { manager.delete(model.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Delete the downloaded model (\(model.sizeLabel))")
            .padding(.trailing, 11)
        }
    }

    private var installed: Bool { manager.installedModelIDs.contains(model.id) }

    private var accessibilityState: String {
        if let progress = manager.downloadProgress[model.id] {
            return "Downloading, \(Int(progress * 100)) percent"
        }
        if model.isAppleBuiltIn { return "Built into macOS, nothing to download" }
        return installed ? "Installed" : "\(model.sizeLabel) to download"
    }
}
