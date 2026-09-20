import SwiftUI

/// The name, set the way the website sets it.
///
/// Avenir Next Heavy with tight tracking and an olive full stop, which
/// is the one place a colour outside the theme is allowed: it belongs to the
/// brand rather than to the palette, so it stays put whichever theme is active.
/// Avenir Next ships with macOS, so nothing has to be bundled or downloaded.
struct Wordmark: View {
    var size: CGFloat = 20

    /// `#7c8531`, matching `.brand-period` on the site.
    private static let period = Color(red: 0.486, green: 0.522, blue: 0.192)

    var body: some View {
        // A single Text with an attributed run, not two views: the period has
        // to sit on the same baseline and inherit the same tracking, which a
        // separate view beside it would not.
        Text(name)
            // Heavy, not Bold: the site asks for weight 750 and CSS resolves
            // that to the next face up, which for Avenir Next is Heavy at 800.
            // Named directly because .fontWeight does not reliably re-pick a
            // face once a custom font has been chosen.
            .font(.custom("AvenirNext-Heavy", size: size))
            .tracking(-size * 0.043)
            .foregroundStyle(Color.mfTextPrimary)
            .fixedSize()
            .accessibilityLabel("MicMyDay")
    }

    private var name: AttributedString {
        var text = AttributedString("MicMyDay")
        var stop = AttributedString(".")
        stop.foregroundColor = Self.period
        text.append(stop)
        return text
    }
}
