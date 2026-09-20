import AppKit
import SwiftUI

/// History (660 × 470).
///
/// There is deliberately no "paste at cursor" button anywhere in here: this
/// window has focus, so there is no cursor to paste into. Pasting belongs to
/// the panel; the window copies.
struct HistoryWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var history: TranscriptHistory

    @State private var selection: UUID?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Color.mfFill(0.06))
            HStack(spacing: 0) {
                list
                Rectangle().fill(Color.mfFill(0.06)).frame(width: 1)
                detail
            }
            Divider().overlay(Color.mfFill(0.06))
            footer
        }
        // An ideal size, not just a range: the detail pane is greedy when nothing
        // is selected and the list's ScrollView reports its content's height, so
        // without one the window opened at whatever those resolved to, which was
        // the full height of the screen.
        .frame(width: 820, height: 600)
        .background(Color.mfCanvas)
        .preferredColorScheme(.dark)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 10) {
            // Clearance for the real traffic lights. The toolbar that centres
            // them against this strip also indents them, so they end further
            // right than they would in a plain titlebar.
            Spacer().frame(width: 84)
            Text("History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mfTextPrimary)
            Text(keptCount)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 150)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.trailing, 14)
        }
        // 52 puts this row's centre exactly on the traffic lights' at 26pt.
        .frame(height: 52)
    }

    private var keptCount: String {
        let total = history.entries.count
        return "\(total) kept \u{00B7} max \(history.limit)"
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(filteredGroups(), id: \.title) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        Text(group.title.uppercased())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.mfCanvas)
                    }
                }
                if history.entries.isEmpty {
                    Text("Nothing dictated yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 264)
        .frame(maxHeight: .infinity)
    }

    private func row(_ entry: TranscriptEntry) -> some View {
        let selected = selection == entry.id
        return Button {
            selection = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.pasted)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mfTextPrimary.opacity(selected ? 1 : 0.75))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                    // Space reserved for the delete control, which is a
                    // sibling overlay: a Button nested in another Button's
                    // label never receives the click.
                    Color.clear.frame(width: 18, height: 12)
                }
                Text(entry.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.mfFill(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(alignment: .topTrailing) {
            Button {
                history.remove(entry.id)
                if selected { selection = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(selected ? 1 : 0.42))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Delete this transcript")
            .padding(.trailing, 10)
            .padding(.top, 7)
        }
    }

    private func filteredGroups() -> [(title: String, entries: [TranscriptEntry])] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return history.grouped() }
        return history.grouped().compactMap { group in
            let matches = group.entries.filter {
                $0.pasted.lowercased().contains(trimmed)
                    || $0.spoken.lowercased().contains(trimmed)
                    || ($0.destinationApp?.lowercased().contains(trimmed) ?? false)
            }
            return matches.isEmpty ? nil : (group.title, matches)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entry.wasRewritten {
                        block(title: "You said", text: entry.spoken, size: 12, maxHeight: 150, secondary: true)
                        wandDivider(entry.profileName ?? "Rewritten")
                        block(title: "Pasted", text: entry.pasted, size: 15, maxHeight: 210, secondary: false)
                    } else {
                        block(
                            title: "Transcript \u{2014} inserted as spoken",
                            text: entry.pasted,
                            size: 15,
                            maxHeight: 290,
                            secondary: false
                        )
                    }
                    facts(entry)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack {
                Text("Select a transcript.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEntry: TranscriptEntry? {
        history.entries.first { $0.id == selection }
    }

    private func block(title: String, text: String, size: CGFloat, maxHeight: CGFloat, secondary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                CopyButton(text: text)
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(text)
                    .font(.system(size: size))
                    .lineSpacing(size > 13 ? 5 : 3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(secondary ? 0.62 : 1))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wandDivider(_ profile: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.mfFill(0.08)).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars").font(.system(size: 10))
                Text(profile).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.mfAccent)
            Rectangle().fill(Color.mfFill(0.08)).frame(height: 1)
        }
    }

    private func facts(_ entry: TranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 22) {
            fact("When", entry.date.formatted(date: .abbreviated, time: .shortened))
            fact("Engine", entry.engineName)
            fact("Delivered", entry.clipboardOnly
                 ? "Clipboard only"
                 : "Pasted into \(entry.destinationApp ?? "the focused app")")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.35))
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Stored on this Mac only and never sent anywhere. Clear all deletes the saved history.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
            Spacer(minLength: 12)
            Button("Clear all") {
                history.clear()
                selection = nil
            }
            .buttonStyle(.beaconQuiet)
            .disabled(history.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Copy icon with the mono "copied — ⌘V" confirmation beside it.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 7) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Copy")

            if copied {
                Text("copied \u{2014} \u{2318}V")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.mfReady)
            }
        }
    }
}
