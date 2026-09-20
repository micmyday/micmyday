import SwiftUI

/// Usage — which model did the work.
///
/// Counters, not a bill. No price is stored or shown, and the numbers never
/// leave the Mac.
///
/// The summary at the top is in words, and only words. A number on its own is
/// read as words by anybody who is not thinking about language models, and
/// "1,001" under CONSUMED will be understood as a thousand words whatever it
/// actually counts, so it had better be words.
///
/// Tokens stay everywhere a bill depends on them, which is every paid provider,
/// but never as a bare figure: where a number is tokens it says so.
///
/// The sections below keep the two jobs apart, because they do not answer the
/// question in the same units: speech arrives as audio, so a transcription
/// model consumes seconds and produces text, while a rewrite model consumes and
/// produces text on both sides.
struct UsagePane: View {
    @ObservedObject var usage: UsageStatistics
    @State private var period: UsagePeriod = .month
    @State private var confirmingReset = false

    var body: some View {
        SummaryCard(summary: usage.summary(in: period), period: $period)

        SettingsCard(
            eyebrow: "Transcription",
            caption: "Audio transcribed, text produced and processing time for each engine."
        ) {
            JobSection(
                counters: usage.counters(for: .transcribe, in: period),
                period: period,
                leading: .audio,
                emptyLine: "No transcriptions in this period."
            )
        }

        SettingsCard(
            eyebrow: "Rewriting",
            caption: "Text processed by each rewrite model, measured in words and tokens. Tokens are the units AI models use to process text."
        ) {
            JobSection(
                counters: usage.counters(for: .rewrite, in: period),
                period: period,
                leading: .tokens,
                emptyLine: "No rewrites in this period."
            )
        }

        let profiles = usage.profileCounters(in: period)
        if !profiles.isEmpty {
            SettingsCard(
                eyebrow: "Usage by profile",
                caption: "Compare how often each rewrite profile is used and how much text it processes."
            ) {
                VStack(spacing: 8) {
                    let busiest = profiles.first?.totals(in: period).runs ?? 1
                    ForEach(profiles) { profile in
                        ProfileRow(
                            totals: profile.totals(in: period),
                            name: profile.profileName,
                            isEstimated: profile.isEstimated,
                            busiest: busiest
                        )
                    }
                }
            }
        }

        SettingsCard(
            eyebrow: "Usage data",
            caption: "Usage statistics for local and cloud models are stored on this Mac. Resetting clears all recorded usage."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let resetAt = usage.resetAt {
                    Text("Counting since \(resetAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                }
                if usage.counters.contains(where: \.isEstimated) {
                    Text("The ≈ symbol marks token counts estimated from the text.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(confirmingReset ? "Confirm reset" : "Reset counters") {
                        if confirmingReset {
                            usage.reset()
                            confirmingReset = false
                        } else {
                            confirmingReset = true
                        }
                    }
                    .buttonStyle(.beaconPlain)
                    if confirmingReset {
                        Button("Cancel") { confirmingReset = false }
                            .buttonStyle(.beaconPlain)
                    }
                }
            }
        }
    }
}

// MARK: - Summary

/// The two totals and the period, then the two dictation-level figures.
private struct SummaryCard: View {
    let summary: UsageDay
    @Binding var period: UsagePeriod

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 0) {
                headline("WORDS IN", summary.wordsIn, dot: .mfAccent)
                Divider().frame(height: 44).overlay(Color.mfHairline).padding(.horizontal, 22)
                headline("WORDS OUT", summary.wordsOut, dot: .mfRecord)
                Spacer(minLength: 14)
                PeriodSwitch(period: $period)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous)
                    .strokeBorder(Color.mfHairline, lineWidth: 1)
            )

            // The word totals include both transcription and rewriting.
            Text("Combined transcription and rewriting totals.")
                .font(.system(size: 11))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                figure("DICTATIONS", summary.runs)
                figure("WORDS TYPED", summary.wordsTyped)
            }
        }
    }

    private func headline(_ label: String, _ value: Int, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }
            // Grouped in full rather than compacted: this is the headline
            // figure, and the one place the exact number is worth the width.
            Text(value.formatted())
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary)
        }
    }

    private func figure(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            Spacer(minLength: 12)
            Text(value.formatted())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.mfFill(0.04), in: RoundedRectangle(cornerRadius: MFMetric.radiusCard, style: .continuous))
    }
}

private struct PeriodSwitch: View {
    @Binding var period: UsagePeriod

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsagePeriod.allCases) { option in
                Button {
                    period = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: period == option ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Color.mfTextPrimary.opacity(period == option ? 1 : 0.55))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            if period == option {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.mfFill(0.10))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Color.mfCanvasDeep, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Per job

private struct JobSection: View {
    /// What the left-hand figure measures, which is the whole reason the two
    /// jobs are drawn separately.
    enum Leading {
        case audio
        case tokens
    }

    let counters: [UsageCounter]
    let period: UsagePeriod
    let leading: Leading
    let emptyLine: String

    var body: some View {
        if counters.isEmpty {
            // An honest line rather than a table of zeros, which would suggest
            // the work happened and came to nothing.
            Text(emptyLine)
                .font(.system(size: 12))
                .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                totals
                Divider().overlay(Color.mfHairline)
                VStack(spacing: 12) {
                    ForEach(counters) { counter in
                        ModelRow(
                            name: counter.displayName,
                            location: counter.location,
                            totals: counter.totals(in: period),
                            isEstimated: counter.isEstimated,
                            leading: leading,
                            busiest: busiest
                        )
                    }
                }
            }
        }
    }

    private var resolved: [UsageDay] { counters.map { $0.totals(in: period) } }

    /// The busiest model sets the length of every bar, so the bars compare
    /// models with each other rather than against a number nobody chose.
    private var busiest: Double {
        resolved.map(weight).max() ?? 1
    }

    private func weight(_ day: UsageDay) -> Double {
        switch leading {
        case .audio: return day.audioSeconds
        case .tokens: return Double(day.tokensIn + day.tokensOut)
        }
    }

    private var totals: some View {
        let sum = resolved.reduce(into: UsageDay()) { $0 = $0 + $1 }
        return HStack(alignment: .top, spacing: 18) {
            switch leading {
            case .audio:
                total("RUNS", sum.runs.formatted())
                total("AUDIO", UsageFormat.duration(sum.audioSeconds))
                total("PROCESSING", UsageFormat.duration(sum.processingSeconds))
                total("WORDS OUT", UsageFormat.compact(sum.wordsOut), tinted: .mfRecord)
                total("TOKENS OUT", UsageFormat.compact(sum.tokensOut), tinted: .mfRecord)
            case .tokens:
                total("RUNS", sum.runs.formatted())
                total("PROCESSING", UsageFormat.duration(sum.processingSeconds))
                total("WORDS IN", UsageFormat.compact(sum.wordsIn), tinted: .mfAccent)
                total("TOKENS IN", UsageFormat.compact(sum.tokensIn), tinted: .mfAccent)
                total("WORDS OUT", UsageFormat.compact(sum.wordsOut), tinted: .mfRecord)
                total("TOKENS OUT", UsageFormat.compact(sum.tokensOut), tinted: .mfRecord)
            }
            Spacer(minLength: 0)
        }
    }

    /// Tokens get a column of their own rather than a smaller line under the
    /// word count. They are the figure a paid provider bills against, and
    /// setting them in the footnote type made the one number with money
    /// attached look like an aside.
    private func total(_ label: String, _ value: String, tinted: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                .fixedSize()
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tinted ?? Color.mfTextPrimary)
        }
    }
}

private struct ModelRow: View {
    let name: String
    let location: String
    let totals: UsageDay
    let isEstimated: Bool
    let leading: JobSection.Leading
    let busiest: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary)
                Text(location)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.4))
                Spacer(minLength: 8)
                Text(pace)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }

            // Length is this model's share of the busiest one; where there are
            // two comparable figures, the split inside it is their ratio.
            GeometryReader { geometry in
                let width = geometry.size.width * share
                HStack(spacing: 0) {
                    Rectangle().fill(Color.mfAccent).frame(width: width * split)
                    Rectangle().fill(Color.mfRecord).frame(width: width * (1 - split))
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            .background(Color.mfFill(0.06), in: Capsule())

            // Two halves rather than one line: "124 + 18 tokens" asks the
            // reader to work out which number is which, and the answer is the
            // whole point of showing both.
            HStack(alignment: .top, spacing: 18) {
                side("IN", incoming, tint: .mfAccent)
                side("OUT", outgoing, tint: .mfRecord)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(location)")
        .accessibilityValue("In, \(incoming). Out, \(outgoing). \(pace)")
    }

    private func side(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(tint.opacity(0.85))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
        }
    }

    /// Speech has no tokens going in, so transcription says what it really
    /// consumed rather than padding the column out.
    private var incoming: String {
        switch leading {
        case .audio:
            return "\(UsageFormat.duration(totals.audioSeconds)) of audio"
        case .tokens:
            return "\(UsageFormat.compact(totals.wordsIn)) words \u{00B7} \(mark)\(UsageFormat.compact(totals.tokensIn)) tokens"
        }
    }

    private var outgoing: String {
        "\(UsageFormat.compact(totals.wordsOut)) words \u{00B7} \(mark)\(UsageFormat.compact(totals.tokensOut)) tokens"
    }

    private var mark: String { isEstimated ? "\u{2248}" : "" }

    /// What one run costs. Named as an average, because "0.49s each" beside
    /// "1 run" reads as a measurement of that one run rather than a mean.
    private var pace: String {
        let runs = "\(totals.runs) \(totals.runs == 1 ? "run" : "runs")"
        guard totals.processingSeconds > 0 else { return runs }
        var line = "\(runs)  \u{00B7}  \(UsageFormat.latency(totals.secondsPerRun)) average"
        if let factor = totals.realtimeFactor {
            line += "  \u{00B7}  \(String(format: "%.1f", factor))\u{00D7} real time"
        }
        return line
    }

    private var share: Double {
        guard busiest > 0 else { return 0 }
        let weight: Double
        switch leading {
        case .audio: weight = totals.audioSeconds
        case .tokens: weight = Double(totals.tokensIn + totals.tokensOut)
        }
        // A model that has run at all gets a visible sliver, so a row is never
        // a label above an empty line.
        return max(0.02, min(1, weight / busiest))
    }

    private var split: Double {
        switch leading {
        case .audio:
            // Seconds of audio against a count of tokens is not a ratio of like
            // things, so this bar stays one colour: its length already says how
            // much of the section this model did.
            return 1
        case .tokens:
            let total = Double(totals.tokensIn + totals.tokensOut)
            return total > 0 ? Double(totals.tokensIn) / total : 0.5
        }
    }
}

private struct ProfileRow: View {
    let totals: UsageDay
    let name: String
    let isEstimated: Bool
    let busiest: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mfTextPrimary)
                Spacer(minLength: 8)
                Text(pace)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.mfTextPrimary.opacity(0.45))
            }
            HStack(alignment: .top, spacing: 18) {
                side("IN", "\(UsageFormat.compact(totals.wordsIn)) words \u{00B7} \(mark)\(UsageFormat.compact(totals.tokensIn)) tokens", tint: .mfAccent)
                side("OUT", "\(UsageFormat.compact(totals.wordsOut)) words \u{00B7} \(mark)\(UsageFormat.compact(totals.tokensOut)) tokens", tint: .mfRecord)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(alignment: .leading) {
            // The fill is this profile's share of the busiest one, so the row
            // itself is the bar and nothing extra has to be drawn.
            GeometryReader { geometry in
                Color.mfAccent.opacity(0.12)
                    .frame(width: geometry.size.width * share)
            }
        }
        .background(Color.mfFill(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue("In, \(totals.wordsIn) words. Out, \(totals.wordsOut) words. \(pace)")
    }

    private func side(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(tint.opacity(0.85))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.mfTextPrimary.opacity(0.55))
        }
    }

    private var mark: String { isEstimated ? "\u{2248}" : "" }

    private var pace: String {
        let runs = "\(totals.runs) \(totals.runs == 1 ? "run" : "runs")"
        guard totals.processingSeconds > 0 else { return runs }
        return "\(runs)  \u{00B7}  \(UsageFormat.latency(totals.secondsPerRun)) average"
    }

    private var share: Double {
        guard busiest > 0 else { return 0 }
        return max(0.03, min(1, Double(totals.runs) / Double(busiest)))
    }
}
