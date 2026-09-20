import Foundation

/// One searchable place in Settings.
///
/// The card's own title is the anchor, so a result knows both what to show and
/// where to scroll. `aliases` is where this earns its keep: people look for a
/// setting by what it does to them, not by what it is called. Somebody who
/// wants music to get quieter while they dictate will search "volume" or
/// "spotify" long before they search "ducking", and both have to land on the
/// same row.
struct SettingsEntry: Identifiable, Equatable {
    let pane: SettingsPane
    /// What the result reads as. Usually the card's own title.
    let card: String
    let aliases: [String]
    /// What the card is addressed by, when that differs from its title: the
    /// cards whose heading changes with the chosen engine or licence state.
    var anchorOverride: String?
    /// Where to send someone when this card turns out not to be on screen.
    ///
    /// Plenty of cards come and go: behind a switch, behind a provider being
    /// connected, behind a licence state, behind a picker being open. Which
    /// of those are true is not knowable from here, and encoding guesses
    /// would be wrong within a week, so this is only a destination of second
    /// choice. Whether the first choice exists is settled by what actually
    /// rendered; see `SettingsSelection.resolveHighlight`.
    var fallbackCard: String?

    /// What the search scrolls to.
    var anchor: String { anchorOverride ?? card }

    var id: String { "\(pane.rawValue).\(anchor)" }
}

/// Everything Settings holds, written out by hand.
///
/// Hand-written rather than derived from the views, for two reasons. SwiftUI
/// offers nothing to read a built interface back out of, and the aliases could
/// not be derived from anything anyway: they are knowledge about how people
/// talk, which exists nowhere in the code. The cost is drift, and that is what
/// `SettingsSearchCoverageTests` is for.
enum SettingsIndex {
    static let entries: [SettingsEntry] = [
        // MARK: General
        SettingsEntry(pane: .general, card: "Theme", aliases: [
            "appearance", "dark mode", "light mode", "colour", "color", "look",
            "system appearance", "night mode",
        ]),
        SettingsEntry(pane: .general, card: "Startup", aliases: [
            "open at login", "launch at login", "start automatically", "autostart",
            "boot", "login item", "run on startup",
        ]),
        SettingsEntry(pane: .general, card: "Sounds", aliases: [
            "play sound cues", "feedback tones", "feedback sounds", "beep", "chime",
            "audio cues", "cue sounds", "transcription sounds", "recording sounds", "error sounds",
        ]),
        // MARK: Output
        SettingsEntry(pane: .output, card: "After you speak", aliases: [
            "paste automatically", "auto paste", "insert", "press return", "send",
            "key to press after pasting", "restore clipboard after pasting",
            "enter key", "end with a space", "trailing space", "give the clipboard back",
            "restore clipboard", "clipboard", "copy", "copied", "pasteboard",
        ]),
        SettingsEntry(pane: .general, card: "History", aliases: [
            "keep recent transcripts", "recent", "past dictations", "transcript history",
            "how many to keep", "remember", "log", "privacy", "delete history",
        ]),

        SettingsEntry(pane: .general, card: "Updates", aliases: [
            "update", "new version", "check for updates", "upgrade", "release",
            "version", "latest", "automatic updates",
        ]),

        // MARK: Voice
        SettingsEntry(pane: .voice, card: "Shortcut", aliases: [
            "hotkey", "keyboard shortcut", "key", "trigger", "right shift", "shortcut",
            "push to talk", "start recording key", "keybinding", "global shortcut",
        ]),
        SettingsEntry(pane: .voice, card: "When you press it", aliases: [
            "hold to talk", "tap to toggle", "activation mode", "press and hold",
            "toggle", "hold", "double tap",
        ]),
        SettingsEntry(pane: .voice, card: "Hands-free", aliases: [
            "hands free", "space", "keep recording after letting go", "long dictation",
            "let go", "spacebar",
        ]),
        SettingsEntry(pane: .voice, card: "Input Monitoring", aliases: [
            "permission", "modifier only shortcut", "right shift", "fn key",
            "shortcut not working", "key not detected",
        ]),
        SettingsEntry(pane: .voice, card: "Microphone", aliases: [
            "microphone", "mic", "input device", "audio input", "headset", "airpods",
            "ducking", "duck", "mute other audio", "lower volume", "turn down music",
            "quieter", "spotify", "background audio", "music",
            "stop after silence", "silence detection", "automatic stop", "pause",
            "start recording when you speak", "voice activation", "hands free start",
            "maximum recording", "length limit", "time limit",
            "countdown", "beep", "warning", "running out", "last seconds",
        ], anchorOverride: "Recording"),

        // MARK: Engine
        SettingsEntry(pane: .engine, card: "Engine", aliases: [
            "model", "whisper", "parakeet", "nemotron", "provider", "openai",
            "gemini", "apple speech", "local", "cloud", "accuracy",
            "download model", "speech to text", "api", "offline",
        ], anchorOverride: "Transcription engine"),
        // Its heading changes with the engine ("Models", "Account", "Your
        // server", "Options"), so it is addressed by a name of its own. This
        // is where a transcription key is entered, which is one of the most
        // searched-for things in any app of this kind.
        SettingsEntry(pane: .engine, card: "Models and account", aliases: [
            "api key", "key", "account", "credentials", "token", "sign in",
            "download models", "model files", "your server", "endpoint", "url",
            "base url", "connect", "openai key", "gemini key",
            "transcribe on this mac only", "on-device recognition", "prefer local", "apple cloud",
        ], anchorOverride: "Engine account"),
        SettingsEntry(pane: .engine, card: "Language", aliases: [
            "spoken language", "english", "german", "deutsch", "french", "spanish",
            "automatic detection", "locale", "accent", "multilingual",
        ]),
        SettingsEntry(pane: .engine, card: "Vocabulary", aliases: [
            "prompt", "names", "jargon", "product names", "bias", "hint", "custom words",
            "spelling", "terminology", "dictionary", "proper nouns",
        ]),
        SettingsEntry(pane: .engine, card: "Corrections", aliases: [
            "replacements", "find and replace", "fix words", "substitutions",
            "text replacement", "always wrong", "misheard", "autocorrect",
        ]),
        SettingsEntry(pane: .engine, card: "Silence", aliases: [
            "silence", "voice detection", "voice activity", "no voice", "nothing said",
            "made up words", "invented", "ghost words", "hallucination", "yeah",
            "empty recording", "quiet",
        ]),
        SettingsEntry(pane: .engine, card: "Filler words", aliases: [
            "um", "uh", "erm", "hesitation", "remove filler", "stop words", "noises",
            "you know", "like",
        ]),
        SettingsEntry(pane: .engine, card: "Live text", aliases: [
            "streaming", "live transcript", "word by word", "partial results",
            "as you speak", "real time", "type while speaking", "direct paste",
        ]),

        // MARK: Rewrite
        SettingsEntry(pane: .rewrite, card: "Rewriting", aliases: [
            "llm", "ai", "clean up", "polish", "tidy", "enable rewriting",
            "post processing", "improve text", "grammar",
        ]),
        SettingsEntry(pane: .rewrite, card: "Rewrite engine", aliases: [
            "which model rewrites it", "rewrite model",
            "provider", "api key", "claude", "anthropic", "openai", "gpt", "gemini",
            "custom endpoint", "ollama", "local model", "on this mac", "key",
            "apple intelligence",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .rewrite, card: "Model", aliases: [
            "local rewrite model", "gguf", "qwen", "gemma", "download", "on device",
            "apple intelligence", "offline rewriting", "size", "disk space",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .rewrite, card: "Profiles", aliases: [
            "rewrite profiles", "presets", "styles", "email", "agent prompt",
            "clean up dictation", "prompts", "custom prompt", "system prompt", "tone",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .rewrite, card: "Edit by voice", aliases: [
            "edit selection", "rewrite selection", "make it shorter", "voice edit",
            "change selected text", "selection",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .rewrite, card: "Cycle profiles", aliases: [
            "next profile", "previous profile", "switch profile", "change profile shortcut", "rotate",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .rewrite, card: "Profile shortcuts", aliases: [
            "per profile hotkey", "dedicated shortcut", "one press", "direct profile key",
        ], fallbackCard: "Rewriting"),
        SettingsEntry(pane: .output, card: "Insert again", aliases: [
            "if it lands in the wrong place", "insert last transcript",
            "insert again", "paste again", "retype", "lost text", "wrong window",
            "missed the paste", "redo insert",
        ]),
        SettingsEntry(pane: .rewrite, card: "What rewriting would do", aliases: [
            "preview", "example", "what it does", "explanation",
        ], fallbackCard: "Rewriting"),

        // MARK: Overlay
        SettingsEntry(pane: .overlay, card: "Overlay", aliases: [
            "pill", "indicator", "badge", "status light", "recording indicator",
            "show overlay", "hud", "on screen", "hide indicator",
        ]),
        SettingsEntry(pane: .overlay, card: "Shape", aliases: [
            "style", "kind", "look", "pill", "dock",
            "panel", "appearance", "which indicator",
        ], fallbackCard: "Overlay"),
        SettingsEntry(pane: .overlay, card: "Time remaining", aliases: [
            "progress", "countdown", "time left", "how long", "limit", "maximum",
            "bar", "line", "elapsed", "running out",
        ], fallbackCard: "Overlay"),
        SettingsEntry(pane: .overlay, card: "Live preview", aliases: [
            "show live text preview",
            "preview", "see the words", "draft", "bubble", "read before it lands",
            "live text panel",
        ], fallbackCard: "Overlay"),
        SettingsEntry(pane: .overlay, card: "Visibility", aliases: [
            "overlay visibility",
            "opacity", "transparency", "dim", "faint", "see through", "alpha",
        ], fallbackCard: "Overlay"),
        SettingsEntry(pane: .overlay, card: "Size", aliases: [
            "compact", "wide", "mini", "big", "small", "scale", "how large",
        ], fallbackCard: "Overlay"),
        SettingsEntry(pane: .overlay, card: "Position", aliases: [
            "where", "corner", "top", "bottom", "centre", "center", "screen",
            "move the pill", "placement",
        ], fallbackCard: "Overlay"),

        // MARK: Permissions
        SettingsEntry(pane: .permissions, card: "macOS permissions", aliases: [
            "microphone", "accessibility", "speech recognition", "input monitoring",
            "privacy", "grant", "denied", "system settings", "allow", "blocked",
        ]),
        SettingsEntry(pane: .permissions, card: "Local servers", aliases: [
            "local network", "ollama", "lan", "localhost", "self hosted", "home network",
        ]),
        SettingsEntry(pane: .permissions, card: "Provider privacy", aliases: [
            "consent", "ask again", "reset choices", "sending audio", "cloud consent",
            "data", "what is sent",
        ]),
        SettingsEntry(pane: .permissions, card: "Refresh permissions", aliases: [
            "not updating",
            "refresh", "recheck", "stuck", "permission not noticed",
        ]),

        // MARK: Usage
        SettingsEntry(pane: .usage, card: "Transcription", aliases: [
            "turning speech into text",
            "usage", "cost", "spend", "minutes", "audio", "counters", "how much",
            "statistics", "stats",
        ]),
        SettingsEntry(pane: .usage, card: "Rewriting", aliases: [
            "rewriting before it is typed",
            "tokens", "cost", "spend", "rewrite usage", "billing", "statistics",
        ]),
        SettingsEntry(pane: .usage, card: "Usage by profile", aliases: [
            "which profile asked for it",
            "per profile usage", "breakdown", "grouped", "statistics",
        ]),
        SettingsEntry(pane: .usage, card: "Usage data", aliases: [
            "these counters",
            "reset counters", "where counted", "privacy of usage", "clear stats",
        ]),

        // MARK: Licence
        SettingsEntry(pane: .licence, card: "Trial", aliases: [
            "free", "days left", "expiry", "evaluation", "trial period",
        ]),
        SettingsEntry(pane: .licence, card: "Trial ended", aliases: [
            "expired", "ran out", "trial over", "licence check needed", "blocked",
        ], anchorOverride: "Trial ended"),
        SettingsEntry(pane: .licence, card: "Activate a licence", aliases: [
            "activate", "enter key", "licence key", "license key", "redeem",
            "paste key", "unlock",
        ], anchorOverride: "Activate a licence"),
        SettingsEntry(pane: .licence, card: "Licence", aliases: [
            "license", "activate", "licence key", "buy", "purchase", "unlock",
            "subscription", "payment", "order", "registration",
        ]),
    ]
}

/// Ranks settings against what someone typed.
///
/// Deliberately tiered rather than one blended number: an exact title always
/// beats an alias, and an alias always beats a loose letter-by-letter match,
/// so the obvious query never has a surprise at the top. Everything below is
/// pure text work over a few dozen entries, so it runs on every keystroke
/// without a thought.
enum SettingsSearch {
    /// Below this, a match is noise. Tuned so a subsequence hit on a long
    /// title still qualifies, while two unrelated letters do not.
    private static let threshold = 0.42

    static func results(
        for rawQuery: String,
        in entries: [SettingsEntry] = SettingsIndex.entries,
        limit: Int = 8
    ) -> [SettingsEntry] {
        let terms = normalise(rawQuery)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        let scored = entries.compactMap { entry -> (entry: SettingsEntry, score: Double)? in
            var total = 0.0
            for term in terms {
                let best = score(term: term, for: entry)
                // Every word has to find something. Otherwise "overlay colour"
                // would rank the overlay rows on the strength of one word,
                // which is not what was asked for.
                guard best > 0 else { return nil }
                total += best
            }
            let average = total / Double(terms.count)
            return average >= threshold ? (entry, average) : nil
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                // Stable and predictable when scores tie: pane order as the
                // window lists them, then alphabetical.
                let left = SettingsPane.allCases.firstIndex(of: $0.entry.pane) ?? 0
                let right = SettingsPane.allCases.firstIndex(of: $1.entry.pane) ?? 0
                if left != right { return left < right }
                return $0.entry.card < $1.entry.card
            }
            .prefix(limit)
            .map(\.entry)
    }

    /// The best any one field can do for one term.
    private static func score(term: String, for entry: SettingsEntry) -> Double {
        var best = quality(term: term, candidate: normalise(entry.card))
        for alias in entry.aliases {
            // Aliases are weighted just under the title, so a card actually
            // called "History" outranks one that merely lists it as another
            // word for something else.
            best = max(best, quality(term: term, candidate: normalise(alias)) * 0.92)
        }
        // The pane's own name counts for something: "voice" should surface the
        // Voice pane's rows even though no card repeats the word.
        best = max(best, quality(term: term, candidate: normalise(entry.pane.title)) * 0.55)
        return best
    }

    /// How well one term matches one piece of text, highest tier wins.
    private static func quality(term: String, candidate: String) -> Double {
        guard !candidate.isEmpty else { return 0 }
        if candidate == term { return 1.0 }
        if candidate.hasPrefix(term) { return 0.9 }

        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.contains(where: { $0 == term }) { return 0.88 }
        if words.contains(where: { $0.hasPrefix(term) }) { return 0.8 }
        // Three characters before a loose substring counts. Two letters in
        // order turn up inside most English words, so "ti" would otherwise
        // match half the window.
        if term.count >= 3, candidate.contains(term) { return 0.7 }
        // A typo in a word somebody typed in full: "ducking" as "duckign".
        // Only for terms long enough that one edit cannot turn them into a
        // different word, which is why three letters and under are excluded.
        if term.count >= 4, words.contains(where: { withinOneEdit(term, $0) }) { return 0.6 }
        // Initials, the way "rp" finds "Refresh permissions".
        if term.count >= 2, words.count >= 2 {
            let initials = String(words.compactMap(\.first))
            if initials.hasPrefix(term) { return 0.58 }
        }
        // Letters in order but not together: "lwrvol" for "lower volume".
        if term.count >= 3, isSubsequence(term, of: candidate) { return 0.5 }
        return 0
    }

    private static func isSubsequence(_ term: String, of candidate: String) -> Bool {
        var remaining = Substring(candidate)
        for character in term {
            guard let index = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }

    /// One insertion, deletion, substitution or swap of neighbours apart.
    ///
    /// Bounded on purpose: a full edit distance would let short words match
    /// each other freely. The swap is not a luxury, it is the typo people
    /// actually make, and it costs two edits on a plain distance, so "duckign"
    /// and "langauge" both missed until it was handled on its own.
    private static func withinOneEdit(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = Array(lhs)
        let right = Array(rhs)
        if abs(left.count - right.count) > 1 { return false }

        if left.count == right.count {
            let differing = zip(left, right).enumerated().filter { $1.0 != $1.1 }.map(\.offset)
            if differing.count == 2, differing[1] == differing[0] + 1,
               left[differing[0]] == right[differing[1]], left[differing[1]] == right[differing[0]] {
                return true
            }
        }

        var i = 0
        var j = 0
        var seenDifference = false
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                i += 1
                j += 1
                continue
            }
            if seenDifference { return false }
            seenDifference = true
            if left.count == right.count {
                i += 1
                j += 1
            } else if left.count < right.count {
                j += 1
            } else {
                i += 1
            }
        }
        return true
    }

    /// Lowercased, stripped of accents and of the punctuation that people drop
    /// when they type a query, so "Not updating?" is reachable as "not
    /// updating" and "hands-free" as "hands free".
    static func normalise(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let cleaned = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(cleaned)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
