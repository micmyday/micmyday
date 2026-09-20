import Speech
import SwiftUI

/// Engine — the picker, what that engine is like, and then only what it needs.
///
/// The per-engine sections are the same views onboarding chapters 3 and 4 use,
/// so the two surfaces cannot drift apart.
struct EnginePane: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var appleLanguageMessage: String?
    @State private var languageAvailabilityRefresh = 0
    @State private var appleSupportedLanguages: [SpokenLanguage] = [SpokenLanguageCatalog.automatic]
    @State private var appleLanguagesPreferOnDevice: Bool?

    var body: some View {
        SettingsCard(eyebrow: "Engine", anchor: "Transcription engine") {
            SettingsRow(title: "Transcription engine") {
                Picker("", selection: $settings.provider) {
                    ForEach(EngineCatalog.selectableProviders(current: settings.provider)) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .dsMenuPicker(width: 220)
            }

            if let engine = EngineCatalog.description(for: settings.provider) {
                let assessment = EngineCatalog.assessment(for: settings)
                Text(engine.line)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 0) {
                    badge("SPEED", rating: assessment.speed)
                    badge("ACCURACY", rating: assessment.accuracy)
                    badge("PRIVACY", rating: engine.privacy)
                    badge("COST", text: engine.cost)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.mfFill(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                // Local guidance appears on each model row below.
                if !settings.provider.isLocalModel {
                    Text(assessment.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        SettingsCard(eyebrow: requirementEyebrow, anchor: "Engine account") {
            switch settings.provider {
            case .whisper, .parakeet, .nemotron: WhisperModelPicker()
            case .openAI: OpenAIConnectSection()
            case .gemini: GeminiConnectSection()
            case .custom: CustomEndpointSection()
            case .appleSpeech: AppleSpeechOptionsSection()
            }
        }

        // Parakeet decides the language itself and takes no language
        // parameter, so there is nothing to set. The card is replaced rather
        // than simply hidden: a stored choice that is being ignored, and an
        // engine that cannot do the language somebody picked, are both worth
        // saying out loud.
        if settings.provider == .parakeet {
            parakeetLanguageCard
        } else {
            SettingsCard(eyebrow: "Language") {
                SettingsRow(title: "Spoken language") {
                    Picker("", selection: $settings.language) {
                        // Keep an existing selection visible when a provider or
                        // mode change makes it unsupported, without offering it
                        // as a selectable option or silently changing the language.
                        if !selectableLanguages.contains(where: { $0.id == settings.language }) {
                            Text(appleLanguagesAreLoading
                                 ? settings.selectedLanguage.name
                                 : "\(settings.selectedLanguage.name) (unavailable)")
                                .tag(settings.language)
                                .disabled(true)
                        }
                        ForEach(selectableLanguages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .dsMenuPicker(width: 220)
                    .disabled(appleLanguagesAreLoading)
                }
                if settings.provider == .appleSpeech, let message = appleLanguageMessage {
                    StatusLabel(
                        text: message,
                        tone: .warn,
                        symbol: "exclamationmark.triangle"
                    )
                }
                languageDescription(languageCaption)
            }
            .task(id: "\(settings.provider.rawValue)|\(settings.preferOnDevice)|\(languageAvailabilityRefresh)") {
                guard settings.provider == .appleSpeech else { return }
                let preferOnDevice = settings.preferOnDevice
                let languages = await AppleSpeechTranscriber.supportedLanguages(preferOnDevice: preferOnDevice)
                guard !Task.isCancelled else { return }
                appleSupportedLanguages = languages
                appleLanguagesPreferOnDevice = preferOnDevice
            }
            .task(id: "\(settings.provider.rawValue)|\(settings.language)|\(settings.preferOnDevice)|\(languageAvailabilityRefresh)") {
                appleLanguageMessage = nil
                guard settings.provider == .appleSpeech else { return }
                let language = settings.selectedLanguage
                let locale = AppleSpeechTranscriber.recognitionLocale(for: language.regionalTag)
                let name = language.id.isEmpty
                    ? (Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                    : language.name
                let availability = await AppleSpeechTranscriber.availability(
                    language: language.regionalTag, preferOnDevice: settings.preferOnDevice
                )
                guard !Task.isCancelled else { return }
                appleLanguageMessage = availability.message(for: name)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Refresh after a user installs a language in System Settings.
                languageAvailabilityRefresh += 1
            }
        }

        // Parakeet takes no contextual strings either, so the same rule applies.
        if settings.provider != .parakeet, settings.provider != .nemotron {
            SettingsCard(
                eyebrow: "Vocabulary",
                caption: "Add words or phrases you want the transcription engine to recognise more accurately."
            ) {
                TextField("Words or phrases…", text: $settings.prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mfTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }

        SettingsCard(
            eyebrow: "Corrections",
            caption: "Automatically replace words or phrases in transcripts. Use corrections to fix spellings or expand a short phrase into longer text."
        ) {
            TextReplacementList()
        }

        SettingsCard(
            eyebrow: "Silence",
            caption: "Skip recordings with no speech to prevent unwanted text in transcripts."
        ) {
            SettingsRow(
                title: "Ignore recordings with no voice in them",
                detail: "Turn this off if a quiet dictation is ever missed."
            ) {
                Toggle("", isOn: $settings.requireVoiceActivity)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
                    .onChange(of: settings.requireVoiceActivity) { _, on in
                        // Turning it on is the moment it is wanted; fetching
                        // it then means it is ready by the next dictation
                        // rather than the one after somebody reads a warning.
                        if on { VoiceActivityModel.shared.ensureReady() }
                    }
            }
            if settings.requireVoiceActivity {
                VoiceActivityReadiness()
            }
        }

        SettingsCard(
            eyebrow: "Filler words",
            caption: "Add or remove words to customise the list."
        ) {
            SettingsRow(
                title: "Remove filler words",
                detail: "Automatically remove fillers like “um” and “uh” from transcripts."
            ) {
                Toggle("", isOn: $settings.removeFillerWords)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
            if settings.removeFillerWords {
                Divider().overlay(Color.mfHairline)
                FillerWordList()
            }
        }

        if settings.provider.supportsStreamingTranscription {
            SettingsCard(
                eyebrow: "Live text",
                caption: "Engines that support it send the transcript back word by word instead of all at once, so you see it forming rather than waiting for the finished text. With Apple Speech the words appear while you are still talking; every other engine takes a finished recording, so there it shortens the wait after you stop rather than removing it."
            ) {
                SettingsRow(title: "While the transcript arrives") {
                    Picker("", selection: $settings.streamingMode) {
                        ForEach(StreamingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .dsMenuPicker(width: 220)
                }

                Text(settings.streamingMode.detail)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                if settings.streamingMode == .directPaste {
                    Text("Rewriting and Corrections both change the transcript after it is complete, which would contradict words already typed into the app. While either is on, this dictation shows in the overlay instead.")
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Written for the engine actually selected. The engines disagree about
    /// what "Automatic" means, and a caption covering all of them at once made
    /// the reader work out which sentence was theirs.
    /// Parakeet's stand-in for the language picker.
    private var parakeetLanguageCard: some View {
        SettingsCard(eyebrow: "Language") {
            if let unsupported = unsupportedParakeetLanguage {
                StatusLabel(
                    text: "Parakeet does not support \(unsupported). Choose Whisper or Nemotron to transcribe this language.",
                    tone: .warn,
                    symbol: "exclamationmark.triangle"
                )
            }
            languageDescription("Parakeet detects the language automatically. It supports 25 European languages.")
        }
    }

    private func languageDescription(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Link("View supported languages", destination: URL(string: "https://micmyday.com/documentation/languages/#language-support")!)
                .font(.system(size: 11))
                .foregroundStyle(Color.mfAccent)
                .buttonStyle(.plain)
        }
    }

    /// The chosen language's name when Parakeet cannot transcribe it, nil when
    /// it can or when the choice is automatic.
    private var unsupportedParakeetLanguage: String? {
        let code = settings.selectedLanguage.id
        guard !code.isEmpty, !SpokenLanguageCatalog.parakeetLanguageCodes.contains(code) else { return nil }
        return settings.selectedLanguage.name
    }

    private var appleLanguagesAreLoading: Bool {
        settings.provider == .appleSpeech && appleLanguagesPreferOnDevice != settings.preferOnDevice
    }

    private var selectableLanguages: [SpokenLanguage] {
        guard settings.provider == .appleSpeech else { return SpokenLanguageCatalog.all }
        return appleLanguagesAreLoading ? [SpokenLanguageCatalog.automatic] : appleSupportedLanguages
    }

    private var languageCaption: String {
        switch settings.provider {
        case .appleSpeech:
            return "Apple Speech cannot detect the language. Automatic means whatever your Mac is set to, so if you dictate in another language, name it here."
        default:
            return "Automatic lets the engine detect the language, which works well for most people. Naming it helps when a recording is short or mixes languages."
        }
    }

    private var selectedLocalEngine: LocalModelEngine {
        WhisperModelCatalog.model(withID: settings.whisperModelID)?.engine ?? .whisper
    }

    private var requirementEyebrow: String {
        switch settings.provider {
        case .whisper, .parakeet, .nemotron: return "Models"
        case .openAI, .gemini: return "Account"
        case .custom: return "Your server"
        case .appleSpeech: return "Options"
        }
    }

    /// Zero means unrated, including models without comparable benchmarks.
    private func badge(_ label: String, rating: Int = 0, text: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            if let text {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.8))
            } else if rating == 0 {
                Text("\u{2014}")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            } else {
                HStack(spacing: 3) {
                    ForEach(1...4, id: \.self) { step in
                        Circle()
                            .fill(step <= rating ? Color.mfAccent : Color.mfFill(0.12))
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text ?? (rating == 0 ? "Unrated" : "\(rating) out of 4"))
    }
}

/// The find-and-replace table behind Settings → Engine → Corrections.
private struct TextReplacementList: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.textReplacements.isEmpty {
                Text("No corrections yet. Add one for any word the engine keeps getting wrong.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }

            ForEach($settings.textReplacements) { $rule in
                HStack(spacing: 8) {
                    Toggle("", isOn: $rule.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help(rule.isEnabled ? "Applied" : "Kept but skipped")

                    field("Heard", text: $rule.spoken)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))

                    field("Written", text: $rule.written)

                    Button {
                        settings.textReplacements.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Remove this correction")
                    .accessibilityLabel("Remove correction")
                }
            }

            Button {
                settings.textReplacements.append(TextReplacement())
            } label: {
                Label("Add correction", systemImage: "plus")
            }
            .buttonStyle(.beaconQuiet)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.mfTextPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: .infinity)
    }
}

/// The editable list behind Settings → Engine → Filler words.
///
/// Chips rather than rows: these are single words with nothing to configure
/// about them, so a table of one-cell rows would be mostly empty space. A word
/// is added by typing it and removed by clicking it.
private struct FillerWordList: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.fillerWords.isEmpty {
                Text("Nothing is being removed. Add the noises you want taken out, or turn the switch off.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(settings.fillerWords, id: \.self) { word in
                        Button {
                            settings.fillerWords.removeAll { $0 == word }
                        } label: {
                            HStack(spacing: 5) {
                                Text(word)
                                    .font(.system(size: 11.5, design: .monospaced))
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.mfCanvasDeep, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Stop removing \"\(word)\"")
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add a word", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mfTextPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.beaconQuiet)
                    .disabled(trimmedDraft.isEmpty)
                Spacer()
                if settings.fillerWords != FillerWords.defaults {
                    Button("Reset") { settings.fillerWords = FillerWords.defaults }
                        .buttonStyle(.beaconQuiet)
                        .help("Back to the words MicMyDay starts with")
                }
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func add() {
        let word = trimmedDraft
        guard !word.isEmpty, !settings.fillerWords.contains(word) else {
            draft = ""
            return
        }
        settings.fillerWords.append(word)
        draft = ""
    }
}

/// Lays chips out left to right, wrapping onto a new line when they run out of
/// room. `HStack` cannot wrap and `LazyVGrid` insists on columns of one width,
/// which looks wrong when the words differ in length as much as these do.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, within: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, within: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}


/// What the silence check is waiting for, when it is waiting for something.
///
/// Silent when everything is in place. The check needs a small file from a
/// third party's servers, and those are occasionally down, so the one thing
/// this must never do is leave a switch showing "on" while nothing happens.
private struct VoiceActivityReadiness: View {
    @ObservedObject private var model = VoiceActivityModel.shared

    var body: some View {
        switch model.state {
        case .ready:
            EmptyView()
        case .fetching:
            StatusLabel(
                text: "Getting what this check needs. Recordings are transcribed as usual until it arrives.",
                tone: .neutral,
                symbol: "arrow.down.circle"
            )
        case .absent:
            row(
                text: "This check is not ready yet. Recordings are transcribed as usual until it is.",
                tone: .warn
            )
        case .failed:
            row(
                text: "What this check needs could not be downloaded. MicMyDay will try again by itself, and recordings are transcribed as usual in the meantime.",
                tone: .warn
            )
        }
    }

    private func row(text: String, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusLabel(text: text, tone: tone, symbol: "exclamationmark.triangle")
            Button("Try now") { VoiceActivityModel.shared.ensureReady(insisting: true) }
                .buttonStyle(.beaconQuiet)
        }
    }
}
