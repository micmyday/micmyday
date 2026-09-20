import SwiftUI

/// The three tips shown once, after the very first successful dictation. It
/// lives in its own floating panel beside the menu bar rather than inside the
/// menu-bar popover, because the advice is *about* that popover.
struct CoachingTipView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let index = appState.coachingTipIndex, index < CoachingTip.all.count {
            let tip = CoachingTip.all[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: tip.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.accent)
                    Text(tip.title)
                        .font(DSFont.ui(13, .semibold))
                        .foregroundStyle(DS.textPrimary)
                    Spacer(minLength: 8)
                    Text("\(index + 1) / \(CoachingTip.all.count)")
                        .font(DSFont.mono(10))
                        .foregroundStyle(DS.textTertiary)
                }

                Text(tip.text)
                    .font(DSFont.ui(12))
                    .lineSpacing(3.5)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Got it") { appState.dismissCoaching() }
                        .buttonStyle(.plain)
                        .font(DSFont.ui(12))
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize()
                    Spacer(minLength: 0)
                    if index < CoachingTip.all.count - 1 {
                        Button("Next tip") { appState.showNextCoachingTip() }
                            .buttonStyle(.link)
                            .font(DSFont.ui(12))
                            .fixedSize()
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
                    .fill(DS.surfaceControl)
            )
            .dsAnimation(DS.fade, value: index)
        }
    }
}
