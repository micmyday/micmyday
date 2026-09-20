import SwiftUI

/// 03 Engine — grouped by whether audio leaves the machine, because that is
/// the trade the choice actually makes.
struct EngineChapter: View {
    @EnvironmentObject private var settings: SettingsStore

    /// The two engines that compete for the same job, recommended first.
    ///
    /// Which of them is recommended depends on the Mac's language, and a list
    /// that recommends its second entry asks the reader to look past the
    /// first one to find the answer.
    private var localEngineCards: [EngineOption] {
        let whisper = EngineOption(
            provider: .whisper,
            name: "Whisper",
            tag: WhisperModelCatalog.recommendedEngine == .whisper ? "RECOMMENDED" : nil,
            facts: ["Free", "Offline", "Up to 100 languages"]
        )
        let parakeet = EngineOption(
            provider: .parakeet,
            name: "Parakeet",
            tag: WhisperModelCatalog.recommendedEngine == .parakeet ? "RECOMMENDED" : nil,
            facts: ["Free", "Offline", "25 languages"]
        )
        return WhisperModelCatalog.recommendedEngine == .parakeet
            ? [parakeet, whisper]
            : [whisper, parakeet]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChapterHeading(
                title: SettingsPane.engine.title,
                lede: SettingsPane.engine.lede
            )

            group(
                label: "LOCAL MODELS & APPLE SPEECH",
                caption: "Local models keep audio on your Mac. Apple Speech can also use Apple’s cloud.",
                labelColor: .mfReady,
                cards: localEngineCards + [
                    EngineOption(
                        provider: .nemotron,
                        name: "Nemotron",
                        tag: nil,
                        facts: ["Free", "Offline", "Live"]
                    ),
                    EngineOption(
                        provider: .appleSpeech,
                        name: "Apple Speech",
                        tag: nil,
                        facts: ["Free", "Local or Apple’s cloud", "Fast"]
                    ),
                ]
            )

            group(
                label: "CLOUD OR YOUR OWN SERVER",
                caption: "Recordings are sent to your chosen provider or server.",
                labelColor: .mfTextPrimary.opacity(0.45),
                cards: [
                    EngineOption(
                        provider: .openAI,
                        name: "OpenAI",
                        tag: nil,
                        facts: ["Pay per use", "Audio sent to OpenAI"]
                    ),
                    EngineOption(
                        provider: .gemini,
                        name: "Gemini",
                        tag: nil,
                        facts: ["API key", "Audio sent to Google"]
                    ),
                    EngineOption(
                        provider: .custom,
                        name: "Custom",
                        tag: nil,
                        facts: ["Your server", "Your choice of model"]
                    ),
                ]
            )

        }
    }

    private func group(label: String, caption: String, labelColor: Color, cards: [EngineOption]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(labelColor)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 12) {
                ForEach(cards) { card in
                    EngineOptionCard(option: card, selected: settings.provider == card.provider) {
                        settings.provider = card.provider
                    }
                }
            }
        }
    }
}

struct EngineOption: Identifiable {
    let provider: TranscriptionProviderKind
    let name: String
    let tag: String?
    let facts: [String]

    var id: String { provider.rawValue }
    var line: String { EngineCatalog.description(for: provider)?.line ?? "" }
}

private struct EngineOptionCard: View {
    let option: EngineOption
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    radio
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(option.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.mfTextPrimary)
                            if let tag = option.tag {
                                Text(tag)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(Color.mfAccent)
                            }
                        }
                        Text(option.line)
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.52))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 6) {
                    ForEach(Array(option.facts.enumerated()), id: \.offset) { index, fact in
                        if index > 0 {
                            Text("\u{00B7}")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mfTextPrimary.opacity(0.25))
                        }
                        Text(fact)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                    }
                }
                .padding(.leading, 24)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.mfAccent.opacity(0.12) : Color.mfFill(0.04),
                in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                    .strokeBorder(selected ? Color.mfAccent : Color.clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Color.mfAccent : Color.mfFill(0.22), lineWidth: 1.5)
                .frame(width: 14, height: 14)
            if selected {
                Circle().fill(Color.mfAccent).frame(width: 7, height: 7)
            }
        }
        .padding(.top, 2)
    }
}
