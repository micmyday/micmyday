import SwiftUI

/// 07 Overlay — what the recording indicator looks like, chosen against the
/// real thing.
///
/// The overlay is the only part of MicMyDay that is on screen while you are
/// using it, and the one somebody is most likely to want moved or changed. It
/// used to be discoverable only by going looking in Settings afterwards, which
/// meant the first dictation was the first time anybody saw it.
///
/// Like Settings → Overlay, the indicator being described is on the real screen
/// while this page is open, in its recording state, at full size and in the
/// place it will actually occupy. A thumbnail here could be wrong; the overlay
/// itself cannot be.
struct OverlayChapter: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ChapterHeading(
                title: "Overlay",
                lede: "A small indicator shows that MicMyDay is listening. It is on screen now — pick the shape you want and watch it change."
            )

            SettingsRow(title: "Show the overlay while recording") {
                Toggle("", isOn: $settings.overlayEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }

            if settings.overlayEnabled {
                shape
                // Each shape asks a different follow-up question, and only
                // where it means something: the pill's size says what it adds
                // as it grows, while the dock's size is decided by whether it
                // is showing words, so it has a surface to choose instead.
                if settings.overlayStyle == .dock {
                    design
                } else {
                    size
                }
                preview
            } else {
                StatusLabel(
                    text: "Nothing will appear while you dictate. You can turn this back on in Settings → Overlay.",
                    tone: .neutral,
                    symbol: "info.circle"
                )
            }
        }
        // The live overlay, started and stopped with the page rather than with
        // the window: the onboarding window is retained, so its own disappear
        // never fires. Closing it mid-chapter is caught in AppState, which
        // turns the preview off once no window that wants it is open.
        .onAppear { appState.setOverlayPreviewing(true) }
        .onDisappear { appState.setOverlayPreviewing(false) }
    }

    private var shape: some View {
        section("SHAPE") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                ForEach(OverlayStyle.allCases) { option in
                    StyleCard(option: option, selected: settings.overlayStyle == option) {
                        settings.overlayStyle = option
                    }
                }
            }
        }
    }

    private var size: some View {
        section("SIZE") {
            HStack(alignment: .top, spacing: 8) {
                ForEach(OverlaySize.allCases) { option in
                    SizeCard(option: option, selected: settings.overlaySize == option) {
                        settings.overlaySize = option
                    }
                }
            }
        }
    }

    private var design: some View {
        section("DESIGN") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(DockStyle.allCases) { option in
                    DockStyleCard(
                        option: option,
                        selected: settings.overlayDockStyle == option
                    ) {
                        settings.overlayDockStyle = option
                    }
                }
            }
        }
    }

    private var preview: some View {
        section("LIVE TEXT") {
            SettingsRow(
                title: "Show words as you speak them",
                detail: "Works with models that run on this Mac, and with Apple Speech in local mode."
            ) {
                Toggle("", isOn: $settings.overlayLivePreview)
                    .labelsHidden().toggleStyle(.switch).tint(.mfAccent)
            }
        }
    }

    /// The same kicker the other chapters set their groups with, so this page
    /// reads as one of them rather than as a settings pane that wandered in.
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            content()
        }
    }
}
