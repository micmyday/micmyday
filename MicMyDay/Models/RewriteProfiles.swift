import CoreGraphics
import Foundation

/// A named rewriting prompt the user can pick per dictation.
///
/// Three ship built in; the user can add any number of their own. A built-in
/// keeps its identity even after its prompt is edited, so "Reset to default"
/// always has something to reset to.
struct RewriteProfile: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let builtin: Bool

    static let builtins: [RewriteProfile] = [
        RewriteProfile(id: "cleanup", name: "Clean up dictation", builtin: true),
        RewriteProfile(id: "agentPrompt", name: "AI agent prompt", builtin: true),
        RewriteProfile(id: "email", name: "Email / message", builtin: true),
    ]

    /// The stock prompt for a profile id. User profiles start from `custom`.
    static func defaultPrompt(for id: String) -> String {
        switch id {
        case "cleanup":
            return "You clean up dictated speech. Remove filler words, false starts and stutters. Fix punctuation, capitalisation and obvious transcription slips. Keep the speaker's wording, meaning and tone \u{2014} do not summarise, answer, or add anything. If the dictation is empty or contains no real content, return it unchanged instead of asking for more. Return only the corrected text."
        case "agentPrompt":
            return "You turn dictated speech into a precise instruction for an AI coding agent. Remove filler, keep every technical detail exactly as spoken (identifiers, paths, versions). Lead with the task in one imperative sentence, then list constraints as short dashed lines. Never invent requirements or answer the request. If the dictation is empty or contains no actionable content, return it unchanged instead of asking for details or writing a placeholder task. Return only the rewritten prompt."
        case "email":
            return "You turn dictated speech into a short, courteous written message. Remove filler, use complete sentences and a neutral professional tone. Keep all facts and requests intact; do not add greetings or sign-offs unless they were spoken. If the dictation is empty or contains no real content, return it unchanged instead of asking for more. Return only the message body."
        default:
            return "Rewrite the dictated text according to your own rules. If the dictated text is empty or contains no real content, return it unchanged. Return only the rewritten text, with no commentary."
        }
    }
}

/// What to press after the transcript is pasted, so a dictated prompt can be
/// sent without reaching for the keyboard. Off by default: pressing Return in
/// the wrong place is destructive, and many email composers treat it as a line
/// break rather than send.
enum AutoSendKey: String, CaseIterable, Identifiable, Codable {
    case off
    case returnKey
    case commandReturn
    case shiftReturn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Don't send"
        case .returnKey: return "Press Return"
        case .commandReturn: return "Press \u{2318}Return"
        case .shiftReturn: return "Press \u{21E7}Return"
        }
    }

    /// Carbon virtual key 36 is Return; the modifiers are CGEvent flags.
    var keyStroke: (keyCode: CGKeyCode, flags: CGEventFlags)? {
        switch self {
        case .off: return nil
        case .returnKey: return (36, [])
        case .commandReturn: return (36, .maskCommand)
        case .shiftReturn: return (36, .maskShift)
        }
    }
}

/// Which model performs the rewrite. Separate from the transcription provider:
/// one turns audio into text, the other rewrites the text.
enum RewriteProviderKind: String, CaseIterable, Identifiable, Codable {
    /// Apple's built-in model or a downloaded model running locally.
    case onDevice
    case anthropic
    case gemini
    case openai
    case custom

    /// Every provider is offered.
    ///
    /// "On this Mac" used to be hidden where macOS had no model of its own,
    /// since offering a choice that can never work is worse than not mentioning
    /// it. It now also covers models the user downloads, which run on every
    /// version this app supports, so the option always leads somewhere. Which
    /// of its models a particular Mac can use is settled in the model list,
    /// where the reason can actually be given.
    static var offered: [RewriteProviderKind] { allCases }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On this Mac"
        case .anthropic: return "Claude API"
        case .gemini: return "Gemini API"
        case .openai: return "OpenAI API"
        case .custom: return "Custom"
        }
    }

    var note: String {
        switch self {
        case .onDevice: return "Private rewriting with local models."
        case .anthropic: return "Cloud models with your Anthropic API key."
        case .gemini: return "Cloud models with your Google AI Studio key."
        case .openai: return "Cloud models with your OpenAI API key."
        case .custom: return "Connect an OpenAI-compatible server."
        }
    }

    /// The hosted endpoint for this provider, nil where the user supplies one.
    var apiBaseURL: String? {
        switch self {
        case .onDevice: return nil
        // Anthropic's own OpenAI-compatible surface, so the same request
        // builder reaches it and nothing here needs a second transport.
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return nil
        }
    }

    /// Preselected in the model list; used until the user picks another.
    var defaultModel: String? {
        switch self {
        case .onDevice: return nil
        case .anthropic: return "claude-sonnet-5"
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-5.6-luna"
        case .custom: return nil
        }
    }

    /// What the provider needs before rewriting can be turned on.
    enum Requirement { case key, url, none }

    var requirement: Requirement {
        switch self {
        case .onDevice: return .none
        case .anthropic, .gemini, .openai: return .key
        case .custom: return .url
        }
    }

    var keyLabel: String {
        switch self {
        case .anthropic: return "Anthropic API key"
        case .gemini: return "Gemini API key for rewriting"
        case .openai: return "OpenAI Platform API key"
        default: return "API key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-\u{2026}"
        case .gemini: return "AIza\u{2026}"
        default: return "sk-\u{2026}"
        }
    }

    var keyHint: String {
        switch self {
        case .anthropic:
            return "Use a key from console.anthropic.com. Claude subscriptions do not include API credit."
        case .gemini:
            return "Create a key at aistudio.google.com. Rewriting can use a different key from transcription."
        case .openai:
            return "Use a key from platform.openai.com. ChatGPT subscriptions do not include API credit."
        default:
            return ""
        }
    }
}

/// One header sent with every request to a self-hosted endpoint. The value is
/// masked in the UI because it is usually a bearer token.
struct CustomHeader: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}
