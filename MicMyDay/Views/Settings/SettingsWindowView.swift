import AppKit
import SwiftUI

/// Settings (900 × 680).
///
/// Not a system preferences pane: no traffic lights, an 18pt radius and a
/// violet glow, so it reads as the same surface as the setup assistant. The
/// only chrome is one circular close button.
struct SettingsWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var selection: SettingsSelection
    @State private var showingPrivacy = false
    @State private var query = ""
    /// The result last opened, so the list can show where you are while it
    /// stays on screen.
    @State private var openedEntry: String?
    @FocusState private var searchFocused: Bool

    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
        }
        .frame(width: 900, height: 680)
        .background {
            Color.mfCanvas
            windowFlare
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) { closeButton }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingPrivacy) { PrivacyPolicyView() }
        // Polling and the overlay-preview reset are tied to the window
        // lifecycle in AppState: onDisappear never fires inside the retained
        // NSHostingController window, so it cannot balance a start here.
        .onChange(of: selection.pane) { _, pane in
            appState.setOverlayPreviewing(pane == .overlay)
        }
        .onChange(of: settings.overlaySize) { _, _ in appState.refreshOverlay() }
        .onChange(of: settings.overlayPosition) { _, _ in appState.refreshOverlay() }
        .onChange(of: settings.overlayOpacity) { _, _ in appState.refreshOverlay() }
        .onChange(of: settings.overlayEnabled) { _, _ in appState.refreshOverlay() }
    }

    /// The window's violet-to-accent flare.
    ///
    /// `radial-gradient(130% 90% at 0% 0%, …)` from the design: an ellipse
    /// centred on the window's top-left corner, 130% of the window wide and 90%
    /// of it tall, faded out by 58% of that radius. The centre lands behind the
    /// rail, so only the tail of it reaches the content pane, which is why the
    /// flare appears to start at the content's leading edge.
    private var windowFlare: some View {
        GeometryReader { geo in
            let radiusX = geo.size.width * 1.30
            let radiusY = geo.size.height * 0.90
            EllipticalGradient(
                stops: [
                    .init(color: Color.mfAccent.opacity(0.15), location: 0),
                    .init(color: Color.mfAccent.opacity(0), location: 0.58),
                ],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.5
            )
            .frame(width: radiusX * 2, height: radiusY * 2)
            .offset(x: -radiusX, y: -radiusY)
        }
    }

    private var closeButton: some View {
        Button(action: onDone) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(Color.mfFill(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(.cancelAction)
        .padding(16)
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("Mark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Wordmark(size: 19)
                    Text("SETTINGS")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 44)
            .padding(.bottom, 24)

            // Twelve, matching the pane list below it rather than the header
            // above it: the rows' backgrounds start at that inset, and a field
            // set to the header's twenty sat visibly narrower than the thing
            // it sits on top of.
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            // The results take the pane list's place rather than appearing
            // beside it: while you are looking for something, the list of
            // eight panes is the thing you have already failed to find it in.
            //
            // Keyed on whether anything was typed, not on whether anything
            // was found. Falling back to the full list when a search found
            // nothing put every pane back on screen under the words "nothing
            // matches", which reads as a contradiction and leaves the user to
            // work out that none of what they are looking at is an answer.
            VStack(spacing: 2) {
                if query.isEmpty {
                    ForEach(SettingsPane.sections) { section in
                        railSection(section)
                    }
                } else {
                    ForEach(results) { entry in
                        resultRow(entry)
                    }
                }
            }
            .padding(.horizontal, 12)

            if !query.isEmpty, results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing matches \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
                    Text("Clear the search to see every pane again.")
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                }
                .font(.system(size: 11))
                .padding(.horizontal, 22)
                .padding(.top, 2)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Button("Privacy & licenses") { showingPrivacy = true }
                    .buttonStyle(.beaconPlain)
                    .font(.system(size: 11))

                Button("Show Setup Assistant") {
                    onDone()
                    appState.showOnboarding()
                }
                .buttonStyle(.beaconPlain)
                .font(.system(size: 11))

                Text("MicMyDay \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.3))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 236, alignment: .leading)
        // Flat and opaque: the flare belongs to the window behind it, and the
        // rail covering its bright half is what makes the rail read as a layer
        // sitting on top of the content pane rather than beside it.
        .background(Color.mfSurfaceFormWindow)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.mfFill(0.06)).frame(width: 1)
        }
    }

    /// What the query finds, empty when nothing was typed.
    private var results: [SettingsEntry] {
        SettingsSearch.results(for: query)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            TextField("Search settings", text: $query)
                .onChange(of: query) { _, _ in openedEntry = nil }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary)
                .focused($searchFocused)
                .onSubmit { open(results.first) }
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.mfFill(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(searchFocused ? Color.mfAccent.opacity(0.5) : Color.mfFill(0.08), lineWidth: 1)
        }
    }

    /// One hit: the card's own title, with the pane it lives in underneath so
    /// the answer to "where was that" is on screen before you click.
    private func resultRow(_ entry: SettingsEntry) -> some View {
        let opened = openedEntry == entry.id
        return Button {
            open(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.pane.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(opened ? Color.mfAccent : Color.mfTextPrimary.opacity(0.35))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.card)
                        .font(.system(size: 12.5, weight: opened ? .semibold : .regular))
                        .foregroundStyle(Color.mfTextPrimary.opacity(opened ? 1 : 0.9))
                        .lineLimit(1)
                    Text(entry.pane.title)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Marked while the list stays up, so a second guess starts from
            // knowing which one has already been tried.
            .background(
                opened ? Color.mfAccent.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// Go to a hit: switch pane, ask its card to show itself, and put the rail
    /// back to its pane list, because the search is finished the moment it has
    /// been answered.
    private func open(_ entry: SettingsEntry?) {
        guard let entry else { return }
        // Whether the pane changes decides whether a report about its cards
        // is coming at all: staying put means the set is already what it will
        // be, and nothing would arrive to settle the request against.
        let staying = selection.pane == entry.pane
        selection.pane = entry.pane
        // Asks for the real destination and names where to go instead if it
        // turns out not to be there. Whether it is there is answered by the
        // pane once it has laid out, not guessed at here.
        selection.highlight(entry.anchor, fallback: entry.fallbackCard, settleNow: staying)
        openedEntry = entry.id
        // The query deliberately survives. A result is a guess at what was
        // meant, and the first guess is often not the right one; clearing the
        // list on the way to it made the second guess cost the whole query
        // again. The field's own clear button ends the search when the user
        // decides it is over.
        searchFocused = false
    }

    /// One labelled group of panes. The label is quiet: it is a heading over
    /// a list, not a thing to click, and it must not compete with the rows.
    private func railSection(_ section: SettingsPane.Section) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.label.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.32))
                .padding(.horizontal, 10)
                .padding(.top, section.panes.first == SettingsPane.sections.first?.panes.first ? 0 : 14)
                .padding(.bottom, 4)
            ForEach(section.panes) { pane in
                navRow(pane)
            }
        }
    }

    private func navRow(_ pane: SettingsPane) -> some View {
        let active = selection.pane == pane
        return Button {
            // Clicking a plain button does not move first responder on macOS,
            // so without this the caret stayed in the search field while the
            // user was evidently done with it.
            searchFocused = false
            selection.forgetHighlight()
            selection.pane = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(active ? Color.mfAccent : Color.mfTextPrimary.opacity(0.4))
                    .frame(width: 16)
                Text(pane.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.mfTextPrimary : Color.mfTextPrimary.opacity(0.62))
                Spacer(minLength: 0)
                if pane == .permissions, !appState.accessibilityGranted {
                    Circle().fill(Color.mfWarn).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                active ? Color.mfAccent.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if active {
                    Capsule()
                        .fill(Color.mfAccent)
                        .frame(width: 2.5)
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Content

    private var content: some View {
        ScrollViewReader { proxy in
            scrollingContent
                // Cards ask to be brought into view when they appear, which is
                // the event that says they exist; a delay guessing at when the
                // pane had finished building would be a race on a slower Mac.
                .environment(\.settingsScrollRequest) { card in
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(card, anchor: .center)
                    }
                }
                .onPreferenceChange(SettingsCardAnchors.self) { anchors in
                    selection.resolveHighlight(against: anchors)
                }
        }
    }

    private var scrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Two lines, not three. The uppercase pane name said what the
                // rail already shows, right next to it, and the headline said
                // in different words what the title says, so the window could
                // disagree with the thing you clicked.
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.pane.title)
                        .font(.system(size: 25, weight: .bold))
                        .tracking(-0.55)
                        .foregroundStyle(Color.mfTextPrimary)
                    Text(selection.pane.lede)
                        .font(.system(size: 12.5))
                        .lineSpacing(4)
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.62))
                        .frame(maxWidth: 470, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    pane
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The theme belongs in this identity as well as the pane. Colour
            // tokens are static properties, so SwiftUI cannot observe them:
            // a view redraws with the new palette only if something else
            // invalidates it. Most cards sit in a pane that observes the
            // settings and so redraw anyway, but a card in a view of its own
            // watching something else entirely, as the Updates card watches
            // the update controller, was never invalidated and kept the old
            // accent on its switch until the window was reopened.
            .id("\(selection.pane.rawValue).\(settings.themeIdentity)")
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch selection.pane {
        case .general: GeneralPane()
        case .voice: VoicePane()
        case .engine: EnginePane()
        case .rewrite: RewritePane()
        case .output: OutputPane()
        case .overlay: OverlayPane()
        case .usage: UsagePane(usage: appState.usage)
        case .licence: LicencePane(licence: appState.licence)
        case .permissions: PermissionsPane()
        case .states: StatesPane()
        }
    }
}

/// A flat card: the only grouping device in the window. No FormSection, no
/// How a card asks to be scrolled into view. Provided by the content pane,
/// which is the only place that holds the scroll proxy.
/// Every card that rendered, by the name search addresses it with. Collected
/// by the content pane so a request can be checked against what exists rather
/// than against a model of when things ought to exist.
struct SettingsCardAnchors: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

private struct SettingsScrollRequestKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var settingsScrollRequest: (String) -> Void {
        get { self[SettingsScrollRequestKey.self] }
        set { self[SettingsScrollRequestKey.self] = newValue }
    }
}

/// grouped-list chrome — each one leads with a mono eyebrow and ends with the
/// caption that explains the control directly above it.
struct SettingsCard<Content: View>: View {
    let eyebrow: String
    var caption: String?
    /// A stable name for this card, for the cards whose heading is computed
    /// and so cannot be one. Search targets this, never the words on screen,
    /// which is what lets a card called "Models" for one engine and "Account"
    /// for another still be one destination.
    var anchor: String?
    @ViewBuilder var content: Content

    @EnvironmentObject private var selection: SettingsSelection
    @Environment(\.settingsScrollRequest) private var scrollRequest

    /// True while a search result is pointing at this card.
    /// What search addresses this card by.
    private var anchorID: String { anchor ?? eyebrow }

    private var isHighlighted: Bool { selection.highlightedCard == anchorID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow.uppercased())
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            content
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHighlighted ? Color.mfAccent : Color.mfFill(0.06),
                              lineWidth: isHighlighted ? 1.5 : 1)
        }
        // The anchor a search result scrolls to has to be this view's
        // identity as well.
        .id(anchorID)
        .preference(key: SettingsCardAnchors.self, value: [anchorID])
        .animation(.easeInOut(duration: 0.22), value: isHighlighted)
        .onAppear(perform: scrollHereIfAsked)
        .onChange(of: selection.highlightRequest) { _, _ in scrollHereIfAsked() }
    }

    /// Called when this card appears and whenever the pointer moves, so a
    /// result in a pane that is already open scrolls just as one in a pane
    /// that has to be built first.
    private func scrollHereIfAsked() {
        guard isHighlighted else { return }
        scrollRequest(anchorID)
    }
}

/// A labelled control row inside a card.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mfTextPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}
