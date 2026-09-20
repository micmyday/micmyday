import SwiftUI

/// Settings → Licence.
///
/// Three states to show and they are genuinely different situations, so each
/// gets its own card rather than one card that changes its mind: still in the
/// trial, licensed, or blocked. Never shows the key in full, because this pane
/// is exactly the thing a user screenshots into a support thread.
struct LicencePane: View {
    /// Observed directly rather than reached through `appState`. A nested
    /// observable object does not republish through its parent, so a pane that
    /// read it via the environment never redrew: the spinner never appeared and
    /// pressing Deactivate looked like nothing had happened.
    @ObservedObject var licence: LicenseManager

    @State private var draft = ""
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        if LicenseManager.isLocalBuild {
            sourceBuildCard
        } else {
            purchasedStates
        }
    }

    /// What a build made from source says instead of asking for a key. There
    /// is nothing to buy here and nothing to activate, so offering either
    /// would be asking somebody to pay for what they already compiled.
    private var sourceBuildCard: some View {
        SettingsCard(
            eyebrow: "Built from source",
            caption: "Built from source and free to use without a licence key. To update, download the latest source and rebuild."
        ,
            anchor: "Licence"
        ) {
            StatusLabel(text: "No licence required", tone: .ok, symbol: "checkmark.seal")
        }
    }

    @ViewBuilder
    private var purchasedStates: some View {
        switch licence.state {
        case let .trial(daysRemaining):
            trialCard(daysRemaining: daysRemaining)
            entryCard(title: "Have a licence key?")
        case .licensed:
            licensedCard
        case .expired, .needsRevalidation:
            blockedCard
            entryCard(title: "Enter your licence key")
        }
    }

    // MARK: - States

    private func trialCard(daysRemaining: Int) -> some View {
        SettingsCard(eyebrow: "Trial") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(daysRemaining)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.mfAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(daysRemaining == 1 ? "day left" : "days left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.mfTextPrimary)
                    Text("All features are available during the trial.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Buy a licence") { openStore() }
                    .buttonStyle(.beacon)
            }
        }
    }

    private var licensedCard: some View {
        SettingsCard(eyebrow: "Licence") {
            SettingsRow(
                title: "Active on this Mac",
                detail: licence.maskedKey.map { key in
                    seatDescription.map { "\(key) · \($0)" } ?? key
                }
            ) {
                StatusLabel(text: "Licensed", tone: .ok, symbol: "checkmark.seal.fill")
            }
            Divider().overlay(Color.mfHairline)
            SettingsRow(
                title: "Move to another Mac",
                detail: "Deactivate this Mac to free an activation for another Mac."
            ) {
                Button {
                    Task { await licence.deactivate() }
                } label: {
                    HStack(spacing: 7) {
                        if licence.isWorking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text(licence.isWorking ? "Releasing…" : "Deactivate")
                    }
                }
                .buttonStyle(.beaconQuiet)
                .disabled(licence.isWorking)
            }
            Divider().overlay(Color.mfHairline)
            SettingsRow(
                title: "Your purchase and keys",
                detail: "View purchases and licence keys in the Polar customer portal. Sign in using the link sent to your email."
            ) {
                Button("Open portal") { openPortal() }
                    .buttonStyle(.beaconQuiet)
            }
            if let error = licence.lastError {
                StatusLabel(text: error.localizedDescription, tone: .warn, symbol: "exclamationmark.triangle")
            }
        }
    }

    private var blockedCard: some View {
        SettingsCard(eyebrow: licence.state == .expired ? "Trial ended" : "Licence check needed",
                     anchor: "Trial ended") {
            VStack(alignment: .leading, spacing: 10) {
                Text(licence.state.blockedReason ?? "")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Color.mfTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if licence.state == .expired {
                    Text("Activate a licence to continue with your saved settings, history and models.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Buy a licence") { openStore() }
                        .buttonStyle(.beacon)
                }
            }
        }
    }

    // MARK: - Entry

    private func entryCard(title: String) -> some View {
        SettingsCard(eyebrow: title, anchor: "Activate a licence") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Paste your licence key", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Color.mfTextPrimary)
                        .focused($keyFieldFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onSubmit { submit() }
                        .disabled(licence.isWorking)
                    Button { submit() } label: {
                        HStack(spacing: 7) {
                            if licence.isWorking {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            }
                            Text(licence.isWorking ? "Checking…" : "Activate")
                        }
                    }
                    .buttonStyle(.beacon)
                    .disabled(licence.isWorking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = licence.lastError {
                    StatusLabel(text: error.localizedDescription, tone: .warn, symbol: "exclamationmark.triangle")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The key is in your purchase receipt.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Find my key") { openPortal() }
                        .buttonStyle(.beaconQuiet)
                }
            }
        }
    }

    /// How many Macs the key covers. Deliberately not "2 of 3 in use": the
    /// licence server tells a client the limit but never how many activations
    /// are spent, so a count here would be invented. Saying what the key covers
    /// is true, and the error on a full key names the number that matters.
    private var seatDescription: String? {
        guard let limit = licence.seatLimit, limit > 0 else { return nil }
        return limit == 1 ? "covers 1 Mac" : "covers \(limit) Macs"
    }

    private func submit() {
        let key = draft
        Task {
            await licence.activate(key: key)
            if licence.state == .licensed { draft = "" }
        }
    }

    /// The customer portal is the only place a customer can retrieve a lost key
    /// or see what they bought. It is worth a permanent door from inside the
    /// app, because someone who has lost their key cannot search their mail for
    /// a receipt they never kept.
    private func openPortal() {
        NSWorkspace.shared.open(PolarLicenseAPI.portalURL)
    }

    private func openStore() {
        guard let url = URL(string: "https://micmyday.com/#pricing") else { return }
        NSWorkspace.shared.open(url)
    }
}
