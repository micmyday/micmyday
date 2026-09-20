import Foundation

/// The 30 glyphs a rewrite profile can be given.
///
/// Deliberately a curated set rather than emoji or an open SF Symbols browser.
/// The constraint that sets the list is the mini overlay: every glyph has to
/// read at 10pt in a 16pt corner badge, so anything with fine detail is out.
struct ProfileIcon: Identifiable, Hashable {
    /// The design's Lucide name, kept as the stored identifier so the two sides
    /// of the handoff stay comparable.
    let id: String
    /// What ships: the SF Symbol equivalent from IconMap.md.
    let symbol: String
    let title: String

    static let all: [ProfileIcon] = [
        // Cleaning up prose
        ProfileIcon(id: "wand-sparkles", symbol: "wand.and.stars", title: "Wand"),
        ProfileIcon(id: "sparkles", symbol: "sparkles", title: "Sparkles"),
        ProfileIcon(id: "eraser", symbol: "eraser", title: "Eraser"),
        ProfileIcon(id: "spell-check", symbol: "textformat.abc", title: "Spelling"),
        ProfileIcon(id: "pilcrow", symbol: "paragraphsign", title: "Paragraph"),
        // Code
        ProfileIcon(id: "terminal", symbol: "terminal", title: "Terminal"),
        ProfileIcon(id: "code", symbol: "chevron.left.forwardslash.chevron.right", title: "Code"),
        ProfileIcon(id: "git-branch", symbol: "arrow.triangle.branch", title: "Branch"),
        ProfileIcon(id: "bug", symbol: "ant.circle", title: "Bug"),
        ProfileIcon(id: "braces", symbol: "curlybraces", title: "Braces"),
        // Messages
        ProfileIcon(id: "mail", symbol: "envelope", title: "Mail"),
        ProfileIcon(id: "message-square", symbol: "bubble.left", title: "Message"),
        ProfileIcon(id: "send", symbol: "paperplane", title: "Send"),
        ProfileIcon(id: "at-sign", symbol: "at", title: "Mention"),
        ProfileIcon(id: "megaphone", symbol: "megaphone", title: "Announcement"),
        // Documents
        ProfileIcon(id: "file-text", symbol: "doc.text", title: "Document"),
        ProfileIcon(id: "notebook-pen", symbol: "square.and.pencil", title: "Notes"),
        ProfileIcon(id: "list-checks", symbol: "checklist", title: "Checklist"),
        ProfileIcon(id: "clipboard-list", symbol: "list.bullet.clipboard", title: "Clipboard"),
        ProfileIcon(id: "quote", symbol: "quote.opening", title: "Quote"),
        // Fields of work
        ProfileIcon(id: "brain", symbol: "brain", title: "Brain"),
        ProfileIcon(id: "graduation-cap", symbol: "graduationcap", title: "Academic"),
        ProfileIcon(id: "stethoscope", symbol: "stethoscope", title: "Medical"),
        ProfileIcon(id: "scale", symbol: "scalemass", title: "Scale"),
        ProfileIcon(id: "briefcase", symbol: "briefcase", title: "Business"),
        // Everything else
        ProfileIcon(id: "languages", symbol: "globe", title: "Languages"),
        ProfileIcon(id: "scissors", symbol: "scissors", title: "Trim"),
        ProfileIcon(id: "gavel", symbol: "hammer", title: "Legal"),
        ProfileIcon(id: "heart", symbol: "heart", title: "Heart"),
        ProfileIcon(id: "zap", symbol: "bolt.fill", title: "Fast"),
    ]

    static let fallback = ProfileIcon(id: "sparkles", symbol: "sparkles", title: "Sparkles")

    static func icon(id: String?) -> ProfileIcon {
        guard let id else { return fallback }
        return all.first { $0.id == id } ?? fallback
    }

    /// The symbol for a stored icon id, or the fallback's.
    static func symbol(for id: String?) -> String { icon(id: id).symbol }

    /// What the built-in profiles start on. A new profile starts on sparkles.
    static func defaultIconID(forProfile profileID: String) -> String {
        switch profileID {
        case "cleanup": return "eraser"
        case "agentPrompt": return "terminal"
        case "email": return "mail"
        default: return "sparkles"
        }
    }
}
