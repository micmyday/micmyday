import Foundation

/// A language the user can force transcription into, and the codes each engine
/// wants for it.
///
/// Engines disagree about the format. whisper.cpp resolves plain ISO 639-1
/// through `whisper_lang_id` and returns -1 for anything with a region, and the
/// OpenAI-style multipart APIs document a plain language code. Gemini's
/// `language_codes` and Apple's `Locale` both take a full BCP-47 tag and use
/// the region. Rather than asking the user to know that, the picker offers
/// languages and this table supplies whichever form an engine needs.
struct SpokenLanguage: Identifiable, Hashable {
    /// ISO 639-1, and the value persisted in settings.
    let id: String
    let name: String
    /// BCP-47 with a region, for Gemini and Apple Speech.
    let regionalTag: String
}

enum SpokenLanguageCatalog {
    /// Empty id means "send no language". Whisper, Gemini and the hosted APIs
    /// then detect the language themselves; Apple Speech cannot, and falls back
    /// to the Mac's current locale, which the Engine pane says plainly.
    static let automatic = SpokenLanguage(id: "", name: "Automatic", regionalTag: "")

    /// What Parakeet can transcribe: 25 European languages, per NVIDIA's model
    /// card for parakeet-tdt-0.6b-v3. It takes no language parameter and works
    /// this out from the audio, so this list is not a picker but a test: of the
    /// languages MicMyDay offers, these eighteen are the ones it can do, and
    /// choosing any of the rest while Parakeet is selected means it will not
    /// transcribe what you say.
    static let parakeetLanguageCodes: Set<String> = [
        "en", "es", "fr", "de", "bg", "hr", "cs", "da", "nl", "et", "fi", "el",
        "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "sv", "ru", "uk",
    ]

    /// The languages Whisper, Gemini and the hosted APIs all handle well.
    /// Sorted by English name; `automatic` stays first in the picker.
    static let all: [SpokenLanguage] = [
        automatic,
        SpokenLanguage(id: "ar", name: "Arabic", regionalTag: "ar-SA"),
        SpokenLanguage(id: "zh", name: "Chinese (Mandarin)", regionalTag: "zh-CN"),
        SpokenLanguage(id: "cs", name: "Czech", regionalTag: "cs-CZ"),
        SpokenLanguage(id: "da", name: "Danish", regionalTag: "da-DK"),
        SpokenLanguage(id: "nl", name: "Dutch", regionalTag: "nl-NL"),
        SpokenLanguage(id: "en", name: "English", regionalTag: "en-US"),
        SpokenLanguage(id: "fi", name: "Finnish", regionalTag: "fi-FI"),
        SpokenLanguage(id: "fr", name: "French", regionalTag: "fr-FR"),
        SpokenLanguage(id: "de", name: "German", regionalTag: "de-DE"),
        SpokenLanguage(id: "el", name: "Greek", regionalTag: "el-GR"),
        SpokenLanguage(id: "he", name: "Hebrew", regionalTag: "he-IL"),
        SpokenLanguage(id: "hi", name: "Hindi", regionalTag: "hi-IN"),
        SpokenLanguage(id: "hu", name: "Hungarian", regionalTag: "hu-HU"),
        SpokenLanguage(id: "id", name: "Indonesian", regionalTag: "id-ID"),
        SpokenLanguage(id: "it", name: "Italian", regionalTag: "it-IT"),
        SpokenLanguage(id: "ja", name: "Japanese", regionalTag: "ja-JP"),
        SpokenLanguage(id: "ko", name: "Korean", regionalTag: "ko-KR"),
        SpokenLanguage(id: "no", name: "Norwegian", regionalTag: "nb-NO"),
        SpokenLanguage(id: "pl", name: "Polish", regionalTag: "pl-PL"),
        SpokenLanguage(id: "pt", name: "Portuguese", regionalTag: "pt-PT"),
        SpokenLanguage(id: "ro", name: "Romanian", regionalTag: "ro-RO"),
        SpokenLanguage(id: "ru", name: "Russian", regionalTag: "ru-RU"),
        SpokenLanguage(id: "sk", name: "Slovak", regionalTag: "sk-SK"),
        SpokenLanguage(id: "es", name: "Spanish", regionalTag: "es-ES"),
        SpokenLanguage(id: "sv", name: "Swedish", regionalTag: "sv-SE"),
        SpokenLanguage(id: "th", name: "Thai", regionalTag: "th-TH"),
        SpokenLanguage(id: "tr", name: "Turkish", regionalTag: "tr-TR"),
        SpokenLanguage(id: "uk", name: "Ukrainian", regionalTag: "uk-UA"),
        SpokenLanguage(id: "vi", name: "Vietnamese", regionalTag: "vi-VN"),
    ]

    /// Resolves a stored value, tolerating anything an older build or a hand
    /// edit may have written ("EN ", "de_DE", "de-DE"). Unknown codes fall back
    /// to automatic rather than reaching an engine that would reject them.
    static func language(forStored value: String) -> SpokenLanguage {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !trimmed.isEmpty else { return automatic }
        let base = String(trimmed.split(separator: "-").first ?? "").lowercased()
        if let exact = all.first(where: { $0.id == base }) { return exact }
        // Aliases and regional tags that do not share the catalog's base code,
        // such as Norwegian Bokmal ("nb") stored under "no".
        if let byRegionalTag = all.first(where: {
            $0.regionalTag.lowercased() == trimmed.lowercased()
                || $0.regionalTag.split(separator: "-").first?.lowercased() == base
        }) {
            return byRegionalTag
        }
        return automatic
    }
}
