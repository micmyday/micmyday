import Foundation
import OSLog

/// What one run of one model consumed and produced.
///
/// Every number here is a by-product of work the engine had already done. The
/// tokenizer belongs to the model, so a count only exists while that model is
/// loaded and the text it produced cannot be turned back into one afterwards;
/// that is why the measurement is taken at the point of inference even though
/// nothing is written to disk until long after.
struct UsageMeasurement: Sendable {
    enum Job: String, Codable, Sendable {
        case transcribe
        case rewrite
    }

    let job: Job
    /// Stable key for the model, as stored: a catalogue id or a provider's
    /// model name.
    let modelID: String
    let displayName: String
    /// Where the work happened, in the user's terms: "This Mac", "OpenAI".
    let location: String
    /// Text the model read. Zero for speech, which arrives as audio.
    var tokensIn: Int = 0
    /// Text the model wrote.
    var tokensOut: Int = 0
    var wordsIn: Int = 0
    var wordsOut: Int = 0
    /// Audio the model listened to. Zero for rewriting.
    var audioSeconds: Double = 0
    /// True when the token counts are worked out from the text rather than
    /// reported by the model. See `estimatedTokens`.
    var isEstimated: Bool = false
    /// How long the model itself took, measured around the inference and not
    /// around loading it. Reading several gigabytes from disk happens once and
    /// says nothing about which model to choose; how long each run takes is the
    /// thing being compared.
    ///
    /// For a provider this includes the network, because that is part of the
    /// wait whether or not it is part of the computation.
    var processingSeconds: Double = 0
    /// The rewrite profile this run served. Empty for transcription, which has
    /// no profile.
    var profileID: String = ""
    var profileName: String = ""
}

/// One rewrite profile's running totals.
///
/// A second view of the same runs. The model rows answer "which should I
/// pick"; these answer "what am I actually using this for", and the two
/// questions have different answers often enough to be worth both.
struct ProfileUsageCounter: Codable, Identifiable, Equatable {
    var id: String { profileID }
    let profileID: String
    var profileName: String
    var days: [String: UsageDay] = [:]
    var isEstimated: Bool = false

    func totals(in period: UsagePeriod, now: Date = Date()) -> UsageDay {
        let earliest = period.earliestDay(now: now)
        return days.reduce(into: UsageDay()) { running, entry in
            guard earliest == nil || entry.key >= earliest! else { return }
            running = running + entry.value
        }
    }
}

extension UsageMeasurement {
    /// This single run, as a day's worth of counters.
    var day: UsageDay {
        UsageDay(
            runs: 1,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            wordsIn: wordsIn,
            wordsOut: wordsOut,
            audioSeconds: audioSeconds,
            processingSeconds: processingSeconds
        )
    }

    /// A rough token count for a model that will not report one.
    ///
    /// Apple's Foundation Models framework exposes no counters, and its
    /// tokenizer is not reachable, so the only thing left is to estimate from
    /// the text. The ratio is the usual rule of thumb, about seventy-five words
    /// to a hundred tokens.
    ///
    /// Counting words and calling them tokens would be the more cautious thing
    /// to print, but it is the less honest one: the pane puts this number in a
    /// column beside real counts, and words would make this model look about a
    /// quarter cheaper than it was. An estimate in the right units beats an
    /// exact count of the wrong thing, as long as it is labelled, which is what
    /// `isEstimated` is for.
    static func estimatedTokens(in text: String) -> Int {
        Int((Double(words(in: text)) * 4.0 / 3.0).rounded())
    }

    /// Words as a person would count them. Deliberately the only definition in
    /// the app, so the figure shown next to a token count and the figure the
    /// estimate is derived from can never drift apart.
    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Where engines drop their measurements during a dictation.
///
/// Optional at every call site and nil unless something is collecting, so an
/// engine never does work for statistics nobody asked for. Adding one is a
/// lock and an append, taken after the engine's real work has finished, so it
/// cannot delay a transcript reaching the cursor.
///
/// A class, and not the store itself, because inference runs off the main
/// actor and the store is main-actor bound. This is the part that crosses.
final class UsageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [UsageMeasurement] = []

    func add(_ measurement: UsageMeasurement) {
        lock.lock()
        collected.append(measurement)
        lock.unlock()
    }

    func drain() -> [UsageMeasurement] {
        lock.lock()
        defer { collected.removeAll(); lock.unlock() }
        return collected
    }
}

/// One day's worth of one model's work.
///
/// Counters are bucketed by day rather than kept as a single running total,
/// because the pane offers a period and a total cannot be filtered back into
/// one. A day is the smallest useful bucket and the largest cheap one: a year
/// of daily rows for a handful of models is a few tens of kilobytes.
struct UsageDay: Codable, Equatable {
    var runs: Int = 0
    var tokensIn: Int = 0
    var tokensOut: Int = 0
    /// The same text counted the way a person reads it. Tokens are what a paid
    /// provider bills, so both are kept: one is the number you are charged for
    /// and the other is the number you can judge.
    var wordsIn: Int = 0
    var wordsOut: Int = 0
    var audioSeconds: Double = 0
    var processingSeconds: Double = 0
    /// Words that reached the cursor. Only meaningful at dictation level, so
    /// it stays zero on a model's own rows.
    var wordsTyped: Int = 0

    static func + (lhs: UsageDay, rhs: UsageDay) -> UsageDay {
        UsageDay(
            runs: lhs.runs + rhs.runs,
            tokensIn: lhs.tokensIn + rhs.tokensIn,
            tokensOut: lhs.tokensOut + rhs.tokensOut,
            wordsIn: lhs.wordsIn + rhs.wordsIn,
            wordsOut: lhs.wordsOut + rhs.wordsOut,
            audioSeconds: lhs.audioSeconds + rhs.audioSeconds,
            processingSeconds: lhs.processingSeconds + rhs.processingSeconds,
            wordsTyped: lhs.wordsTyped + rhs.wordsTyped
        )
    }
}

/// Which stretch of time the pane is showing.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "This month"
        case .all: return "All time"
        }
    }

    /// The earliest day included, or nil for all of them. Calendar arithmetic
    /// rather than subtracting seconds, so a week is seven days and not
    /// 604,800 seconds across a daylight-saving change.
    func earliestDay(now: Date = Date(), calendar: Calendar = UsageDayKey.calendar) -> String? {
        switch self {
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -6, to: now) else { return nil }
            return UsageDayKey.key(for: start, calendar: calendar)
        case .month:
            // Built through the same Gregorian calendar the keys use, or "this
            // month" would mean a different month from the one they record.
            let gregorian = UsageDayKey.key(for: now, calendar: calendar)
            return String(gregorian.prefix(7)) + "-01"
        case .all:
            return nil
        }
    }
}

/// Day keys are sortable strings, so a period is a string comparison rather
/// than a date parse for every bucket.
enum UsageDayKey {
    /// Always Gregorian, in the Mac's current time zone.
    ///
    /// The calendar is pinned because a key is a permanent record and the
    /// user's calendar is a display preference they may change. Read through a
    /// Chinese calendar, two dates a month apart both came out as the same key,
    /// which merged their months; through a Buddhist one the years differ and
    /// the whole history falls outside every period. The time zone is not
    /// pinned, because which day it was is a question about where the user was.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func key(for date: Date = Date(), calendar: Calendar = UsageDayKey.calendar) -> String {
        var calendar = calendar
        // Anything handed in keeps its time zone but not its calendar system.
        if calendar.identifier != .gregorian {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            calendar = gregorian
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One model's running totals.
struct UsageCounter: Codable, Identifiable, Equatable {
    var id: String { "\(job.rawValue):\(location):\(modelID)" }

    let job: UsageMeasurement.Job
    let modelID: String
    var displayName: String
    var location: String
    /// Keyed by day, so any period can be summed back out of it.
    var days: [String: UsageDay] = [:]
    /// True when any run folded into this row was estimated rather than
    /// counted, so the pane can mark the figure as approximate. Once a row
    /// contains an estimate it never becomes exact again, which is the honest
    /// direction for this flag to travel.
    var isEstimated: Bool = false
    var firstUsed: Date
    var lastUsed: Date

    /// Everything this model did within `period`.
    func totals(in period: UsagePeriod, now: Date = Date()) -> UsageDay {
        let earliest = period.earliestDay(now: now)
        return days.reduce(into: UsageDay()) { running, entry in
            guard earliest == nil || entry.key >= earliest! else { return }
            running = running + entry.value
        }
    }
}

/// Per-model counters for the work MicMyDay has done.
///
/// Deliberately counters and not a ledger: the question this answers is which
/// model consumed and produced how much, not what any of it cost. No prices
/// are stored, and nothing here leaves the Mac.
///
/// Nothing in this type may ever be able to slow a dictation down or fail one.
/// Recording appends to memory and schedules a coalesced write; a failure to
/// save is logged and otherwise ignored, because a lost counter is a far
/// smaller problem than a lost transcript.
@MainActor
final class UsageStatistics: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.micmyday.app", category: "Usage")

    @Published private(set) var counters: [UsageCounter] = []
    @Published private(set) var profiles: [ProfileUsageCounter] = []
    /// Dictation-level counts, which belong to no single model.
    @Published private(set) var dictationDays: [String: UsageDay] = [:]
    @Published private(set) var resetAt: Date?

    private let storeURL: URL?
    private var saveTask: Task<Void, Never>?

    init(storeURL: URL? = UsageStatistics.defaultStoreURL) {
        self.storeURL = storeURL
        load()
    }

    nonisolated static var defaultStoreURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("MicMyDay/usage.json")
    }

    /// Folds a dictation's measurements into the totals.
    ///
    /// Called after the transcript has been delivered, never before: by that
    /// point the dictation is over and nothing this does can hold it up.
    func record(_ measurements: [UsageMeasurement], wordsTyped: Int = 0) {
        let today = UsageDayKey.key()
        if wordsTyped > 0 {
            // Dictation-level, not model-level: one dictation types one set of
            // words however many models touched it.
            var day = dictationDays[today] ?? UsageDay()
            day.runs += 1
            day.wordsTyped += wordsTyped
            dictationDays[today] = day
        }
        guard !measurements.isEmpty || wordsTyped > 0 else { return }

        for measurement in measurements {
            let now = Date()
            // Keyed by where it ran as well as what it is: the same alias
            // pointed at two different endpoints is two different models, and
            // their speed is the whole reason to tell them apart.
            let index = counters.firstIndex {
                $0.job == measurement.job
                    && $0.modelID == measurement.modelID
                    && $0.location == measurement.location
            }
            if let index {
                counters[index].days[today] = (counters[index].days[today] ?? UsageDay()) + measurement.day
                counters[index].isEstimated = counters[index].isEstimated || measurement.isEstimated
                counters[index].lastUsed = now
                // A model that was renamed keeps its totals but describes
                // itself the way it does now. Its location is part of its
                // identity, so that is not updated here.
                counters[index].displayName = measurement.displayName
            } else {
                counters.append(UsageCounter(
                    job: measurement.job,
                    modelID: measurement.modelID,
                    displayName: measurement.displayName,
                    location: measurement.location,
                    days: [today: measurement.day],
                    isEstimated: measurement.isEstimated,
                    firstUsed: now,
                    lastUsed: now
                ))
            }
            recordProfile(measurement, on: today)
        }
        save()
    }

    private func recordProfile(_ measurement: UsageMeasurement, on today: String) {
        guard measurement.job == .rewrite, !measurement.profileID.isEmpty else { return }
        if let index = profiles.firstIndex(where: { $0.profileID == measurement.profileID }) {
            profiles[index].days[today] = (profiles[index].days[today] ?? UsageDay()) + measurement.day
            profiles[index].isEstimated = profiles[index].isEstimated || measurement.isEstimated
            profiles[index].profileName = measurement.profileName
        } else {
            profiles.append(ProfileUsageCounter(
                profileID: measurement.profileID,
                profileName: measurement.profileName,
                days: [today: measurement.day],
                isEstimated: measurement.isEstimated
            ))
        }
    }

    /// Everything done in `period`, across every model and both jobs, plus the
    /// dictation-level figures the summary shows.
    func summary(in period: UsagePeriod, now: Date = Date()) -> UsageDay {
        let earliest = period.earliestDay(now: now)
        let models = counters.reduce(into: UsageDay()) { $0 = $0 + $1.totals(in: period, now: now) }
        let dictations = dictationDays.reduce(into: UsageDay()) { running, entry in
            guard earliest == nil || entry.key >= earliest! else { return }
            running = running + entry.value
        }
        // `runs` on a model row counts that model's runs; the summary wants
        // dictations, which is the dictation-level count.
        var combined = models
        combined.runs = dictations.runs
        combined.wordsTyped = dictations.wordsTyped
        return combined
    }

    func profileCounters(in period: UsagePeriod, now: Date = Date()) -> [ProfileUsageCounter] {
        profiles
            .filter { $0.totals(in: period, now: now).runs > 0 }
            .sorted { $0.totals(in: period, now: now).runs > $1.totals(in: period, now: now).runs }
    }

    func counters(for job: UsageMeasurement.Job, in period: UsagePeriod, now: Date = Date()) -> [UsageCounter] {
        counters
            .filter { $0.job == job && $0.totals(in: period, now: now).runs > 0 }
            .sorted { $0.totals(in: period, now: now).runs > $1.totals(in: period, now: now).runs }
    }

    func reset() {
        counters = []
        profiles = []
        dictationDays = [:]
        resetAt = Date()
        flush()
    }

    /// Writes now rather than waiting out the coalescing delay, so counters
    /// from the last moments before a quit are not the ones that get lost.
    func flush() {
        saveTask?.cancel()
        guard let storeURL else { return }
        // Synchronous on purpose: the caller is quitting or has just cleared
        // the counters, and in both cases there is nothing left to hold up.
        Self.write(
            Store(counters: counters, profiles: profiles,
                  dictationDays: dictationDays, resetAt: resetAt),
            to: storeURL
        )
    }

    /// Puts counters in place directly, for tests that need a history.
    /// `record` can only ever write today, so a period cannot be exercised
    /// through it.
    func replaceForTesting(counters: [UsageCounter]) {
        self.counters = counters
    }

    // MARK: - Persistence

    /// Coalesced, for the same reason history is: a burst of dictations should
    /// not each rewrite the file.
    ///
    /// Detached, and not merely low priority. A `Task` started from here would
    /// inherit this actor, which is the main one, and `.utility` would lower
    /// its priority without moving it: encoding the whole store and writing it
    /// to disk would run on the main actor and could hold up the controls of
    /// the next dictation. Measured at 14 ms after a year of daily use and
    /// 93 ms after ten, which is exactly the kind of thing that must not be on
    /// the path of the job.
    private func save() {
        saveTask?.cancel()
        guard let storeURL else { return }
        let snapshot = Store(
            counters: counters, profiles: profiles,
            dictationDays: dictationDays, resetAt: resetAt
        )
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: storeURL)
        }
    }

    fileprivate struct Store: Codable, Sendable {
        var counters: [UsageCounter]
        var profiles: [ProfileUsageCounter] = []
        var dictationDays: [String: UsageDay] = [:]
        var resetAt: Date?
    }

    /// Nonisolated so it can run anywhere, which is the point of the detached
    /// task above. Failures are logged and otherwise ignored: a lost counter is
    /// a far smaller problem than a lost transcript.
    nonisolated private static func write(_ store: Store, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(store)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("Could not save usage counters: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return }
        guard let store = try? JSONDecoder().decode(Store.self, from: data) else {
            Self.logger.error("Usage counters could not be read; starting from zero")
            return
        }
        counters = store.counters
        profiles = store.profiles
        dictationDays = store.dictationDays
        resetAt = store.resetAt
    }
}


extension UsageDay {
    /// What one run typically costs in time, which is the figure a choice
    /// between models actually turns on.
    var secondsPerRun: Double {
        runs > 0 ? processingSeconds / Double(runs) : 0
    }

    /// How much faster than real time this engine transcribes: a minute of
    /// speech handled in fifteen seconds is four times. Only meaningful where
    /// there was audio, so nil for rewriting.
    var realtimeFactor: Double? {
        guard audioSeconds > 0, processingSeconds > 0 else { return nil }
        return audioSeconds / processingSeconds
    }
}

/// How counters are written out.
///
/// In the model rather than the view because the boundaries are where the
/// mistakes are, and a view is an awkward place to check them from.
enum UsageFormat {
    /// Whole units only. A counter is read at a glance, and "1,204,883" tells
    /// nobody more than "1.2M".
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return "\(value / 1000)k"
        case 1_000...: return String(format: "%.1fk", Double(value) / 1000)
        default: return "\(value)"
        }
    }

    /// Coarsening as it grows, because nobody needs the seconds in four hours
    /// of dictation but everybody needs them in four seconds of it.
    /// Short spans, where a tenth of a second is the difference between two
    /// models and rounding to whole seconds would hide it.
    static func latency(_ seconds: Double) -> String {
        if seconds >= 60 { return duration(seconds) }
        if seconds >= 10 { return String(format: "%.1fs", seconds) }
        return String(format: "%.2fs", seconds)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }
}


extension Duration {
    /// Seconds as a Double. `components` gives whole seconds plus attoseconds,
    /// which is exact but not a number anything here can add up.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
