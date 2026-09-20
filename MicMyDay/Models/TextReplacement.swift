import Foundation

/// A find-and-replace applied to the finished transcript.
///
/// Deliberately separate from the vocabulary hints in Settings → Engine. Those
/// are sent *to* the engine to bias what it hears, which helps but never
/// guarantees; this runs *after* transcription, so a spelling it fixes stays
/// fixed. It is also free, instant and offline, and doubles as snippet
/// expansion when the replacement is longer than the phrase.
struct TextReplacement: Identifiable, Codable, Equatable {
    var id = UUID()
    /// What was heard.
    var spoken: String
    /// What should be written instead.
    var written: String
    /// When false the rule is kept but skipped, so a rule can be parked
    /// without losing it.
    var isEnabled = true

    init(id: UUID = UUID(), spoken: String = "", written: String = "", isEnabled: Bool = true) {
        self.id = id
        self.spoken = spoken
        self.written = written
        self.isEnabled = isEnabled
    }
}

enum TextReplacementEngine {
    /// Applies every enabled rule to `text`.
    ///
    /// Matching is case-insensitive and diacritic-insensitive on whole words,
    /// so "micmyday" and "Micmyday" both become "MicMyDay" while "micmydayish"
    /// is left alone. Longer phrases are applied first, so a rule for "visual
    /// studio code" wins over one for "code". Replacements are never re-scanned,
    /// so rules cannot chain into each other or loop.
    static func apply(_ rules: [TextReplacement], to text: String) -> String {
        let active = rules
            .filter { $0.isEnabled && !$0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        guard !active.isEmpty, !text.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        outer: while index < text.endIndex {
            if isWordStart(text, index) {
                for rule in active {
                    let phrase = rule.spoken.trimmingCharacters(in: .whitespaces)
                    guard
                        let end = text.index(index, offsetBy: phrase.count, limitedBy: text.endIndex),
                        text[index ..< end].compare(
                            phrase,
                            options: [.caseInsensitive, .diacriticInsensitive]
                        ) == .orderedSame,
                        isWordEnd(text, end)
                    else { continue }
                    result.append(rule.written)
                    index = end
                    continue outer
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// True when nothing word-like precedes this position.
    private static func isWordStart(_ text: String, _ index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber
    }

    /// True when nothing word-like follows this position.
    private static func isWordEnd(_ text: String, _ index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text[index]
        return !next.isLetter && !next.isNumber
    }
}
