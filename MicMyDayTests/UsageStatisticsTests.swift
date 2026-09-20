import XCTest
@testable import MicMyDay

/// The counters, and the promise that they cannot get in the way.
///
/// The rule this file exists to protect: statistics must never slow down or
/// fail a dictation. Counting is free because every number is a by-product of
/// work the engine already did, and the only expensive part, writing to disk,
/// happens after the transcript has been delivered.
final class UsageStatisticsTests: XCTestCase {
    private func makeStore() -> (UsageStatistics, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString).json")
        return (MainActor.assumeIsolated { UsageStatistics(storeURL: url) }, url)
    }

    @MainActor
    func testRunsOfTheSameModelAccumulateIntoOneRow() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let run = UsageMeasurement(
            job: .rewrite, modelID: "qwen3.5-2b", displayName: "Qwen3.5 2B",
            location: "This Mac", tokensIn: 100, tokensOut: 40
        )
        usage.record([run])
        usage.record([run])

        XCTAssertEqual(usage.counters.count, 1, "The same model must not produce a second row")
        XCTAssertEqual(usage.counters[0].totals(in: .all).runs, 2)
        XCTAssertEqual(usage.counters[0].totals(in: .all).tokensIn, 200)
        XCTAssertEqual(usage.counters[0].totals(in: .all).tokensOut, 80)
    }

    /// Transcribing and rewriting are separate sections in the design, and a
    /// model can legitimately do both.
    @MainActor
    func testTheSameModelInTwoJobsIsTwoRows() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([
            UsageMeasurement(job: .transcribe, modelID: "m", displayName: "M", location: "This Mac"),
            UsageMeasurement(job: .rewrite, modelID: "m", displayName: "M", location: "This Mac"),
        ])
        XCTAssertEqual(usage.counters.count, 2)
        XCTAssertEqual(usage.counters(for: .transcribe, in: .all).count, 1)
        XCTAssertEqual(usage.counters(for: .rewrite, in: .all).count, 1)
    }

    /// Speech arrives as audio, so a transcription row measures what it
    /// consumed in seconds and leaves input tokens at zero rather than
    /// inventing a number for them.
    @MainActor
    func testTranscriptionCountsSecondsNotInputTokens() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .transcribe, modelID: "parakeet", displayName: "Parakeet",
            location: "This Mac", tokensOut: 31, audioSeconds: 4.5
        )])
        XCTAssertEqual(usage.counters[0].totals(in: .all).tokensIn, 0, "Audio is not text and must not be counted as tokens")
        XCTAssertEqual(usage.counters[0].totals(in: .all).tokensOut, 31)
        XCTAssertEqual(usage.counters[0].totals(in: .all).audioSeconds, 4.5, accuracy: 0.001)
    }

    @MainActor
    func testCountersSurviveARestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UsageStatistics(storeURL: url)
        first.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "This Mac",
            tokensIn: 7, tokensOut: 3
        )])
        first.flush()

        let second = UsageStatistics(storeURL: url)
        XCTAssertEqual(second.counters.count, 1)
        XCTAssertEqual(second.counters[0].totals(in: .all).tokensIn, 7)
        XCTAssertEqual(second.counters[0].totals(in: .all).tokensOut, 3)
    }

    /// A store that cannot write must still count, and must not throw. Losing a
    /// counter is a far smaller problem than losing a transcript, and the
    /// dictation path calls this.
    @MainActor
    func testAnUnwritableStoreDoesNotFailTheRecording() {
        let unwritable = URL(fileURLWithPath: "/System/nowhere/usage.json")
        let usage = UsageStatistics(storeURL: unwritable)
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "This Mac", tokensIn: 1
        )])
        usage.flush()
        XCTAssertEqual(usage.counters.count, 1, "Counting happens in memory and cannot depend on the disk")
    }

    @MainActor
    func testResetEmptiesTheCountersAndRecordsWhen() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(job: .rewrite, modelID: "m", displayName: "M", location: "x")])
        XCTAssertNil(usage.resetAt)
        usage.reset()
        XCTAssertTrue(usage.counters.isEmpty)
        XCTAssertNotNil(usage.resetAt)
    }

    // MARK: - The probe

    /// The probe crosses from inference, which runs off the main actor, to the
    /// store, which does not. Concurrent appends must not lose or corrupt one.
    func testTheProbeCollectsFromManyThreadsAtOnce() {
        let probe = UsageProbe()
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            probe.add(UsageMeasurement(
                job: .rewrite, modelID: "m\(index % 5)", displayName: "M",
                location: "This Mac", tokensIn: 1
            ))
        }
        XCTAssertEqual(probe.drain().count, 500)
    }

    func testDrainingLeavesTheProbeEmpty() {
        let probe = UsageProbe()
        probe.add(UsageMeasurement(job: .rewrite, modelID: "m", displayName: "M", location: "x"))
        XCTAssertEqual(probe.drain().count, 1)
        XCTAssertEqual(probe.drain().count, 0, "A drained probe must not report the same run twice")
    }

    /// Nothing is recorded for a dictation that produced no measurements, so a
    /// cancelled or failed one leaves no trace in the counters.
    @MainActor
    func testAnEmptyDrainChangesNothing() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record(UsageProbe().drain())
        XCTAssertTrue(usage.counters.isEmpty)
    }

    // MARK: - Estimating, for a model that will not say

    func testTheEstimateIsInTokensRatherThanWords() {
        // Twelve words. At roughly seventy-five words to a hundred tokens that
        // is sixteen, not twelve: counting words here would understate this
        // model against every other row in the pane.
        let text = "one two three four five six seven eight nine ten eleven twelve"
        XCTAssertEqual(UsageMeasurement.estimatedTokens(in: text), 16)
    }

    func testTheEstimateHandlesEmptyAndRaggedText() {
        XCTAssertEqual(UsageMeasurement.estimatedTokens(in: ""), 0)
        XCTAssertEqual(UsageMeasurement.estimatedTokens(in: "   \n  "), 0)
        // Runs of whitespace and newlines are separators, not words.
        XCTAssertEqual(UsageMeasurement.estimatedTokens(in: "one\n\ntwo   three"), 4)
    }

    func testTheEstimateGrowsWithTheText() {
        let short = UsageMeasurement.estimatedTokens(in: "a short line here")
        let long = UsageMeasurement.estimatedTokens(in: String(repeating: "a short line here ", count: 10))
        XCTAssertGreaterThan(long, short * 8)
    }

    /// A row that contains an estimate must say so, and must keep saying so:
    /// mixing an estimate into exact counts does not make the total exact.
    @MainActor
    func testAnEstimateMarksTheRowAndNeverUnmarksIt() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "apple-built-in", displayName: "Apple built-in",
            location: "This Mac", tokensIn: 16, tokensOut: 8, isEstimated: true
        )])
        XCTAssertTrue(usage.counters[0].isEstimated)

        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "apple-built-in", displayName: "Apple built-in",
            location: "This Mac", tokensIn: 4, tokensOut: 2
        )])
        XCTAssertTrue(usage.counters[0].isEstimated, "One estimate makes the whole total approximate")
        XCTAssertEqual(usage.counters[0].totals(in: .all).tokensIn, 20)
    }

    /// Counted models must not be tarred with the same brush.
    @MainActor
    func testACountedRowStaysExact() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "qwen3.5-2b", displayName: "Qwen3.5 2B",
            location: "This Mac", tokensIn: 100, tokensOut: 40
        )])
        XCTAssertFalse(usage.counters[0].isEstimated)
    }

    // MARK: - How the numbers read

    /// The boundaries are where a compacted number goes wrong, so each one is
    /// pinned rather than sampled.
    func testCompactNumbersChangeUnitAtTheRightPoints() {
        XCTAssertEqual(UsageFormat.compact(0), "0")
        XCTAssertEqual(UsageFormat.compact(999), "999")
        XCTAssertEqual(UsageFormat.compact(1_000), "1.0k")
        XCTAssertEqual(UsageFormat.compact(1_540), "1.5k")
        XCTAssertEqual(UsageFormat.compact(9_999), "10.0k")
        XCTAssertEqual(UsageFormat.compact(10_000), "10k")
        XCTAssertEqual(UsageFormat.compact(999_999), "999k")
        XCTAssertEqual(UsageFormat.compact(1_000_000), "1.0M")
        XCTAssertEqual(UsageFormat.compact(1_240_000), "1.2M")
    }

    func testCompactNumbersNeverGetLongerThanTheNumber() {
        for value in [0, 7, 99, 999, 1_000, 12_345, 999_999, 5_000_000] {
            XCTAssertLessThanOrEqual(
                UsageFormat.compact(value).count, 6,
                "\(value) compacted to something too wide for the row"
            )
        }
    }

    func testDurationsCoarsenAsTheyGrow() {
        XCTAssertEqual(UsageFormat.duration(0), "0s")
        XCTAssertEqual(UsageFormat.duration(4.4), "4s")
        XCTAssertEqual(UsageFormat.duration(4.6), "5s")
        XCTAssertEqual(UsageFormat.duration(59), "59s")
        XCTAssertEqual(UsageFormat.duration(60), "1m 0s")
        XCTAssertEqual(UsageFormat.duration(3_599), "59m 59s")
        XCTAssertEqual(UsageFormat.duration(3_600), "1h 0m")
        XCTAssertEqual(UsageFormat.duration(7_830), "2h 10m")
    }

    // MARK: - Time, which is what a choice between models turns on

    @MainActor
    func testProcessingTimeAccumulatesAndAverages() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        for seconds in [1.0, 2.0, 3.0] {
            usage.record([UsageMeasurement(
                job: .rewrite, modelID: "m", displayName: "M", location: "This Mac",
                processingSeconds: seconds
            )])
        }
        XCTAssertEqual(usage.counters[0].totals(in: .all).processingSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(usage.counters[0].totals(in: .all).secondsPerRun, 2, accuracy: 0.001)
    }

    /// The figure that answers "is this engine fast enough": a minute of speech
    /// handled in fifteen seconds is four times real time.
    @MainActor
    func testRealtimeFactorComparesAudioAgainstTimeSpent() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .transcribe, modelID: "p", displayName: "P", location: "This Mac",
            audioSeconds: 60, processingSeconds: 15
        )])
        XCTAssertEqual(usage.counters[0].totals(in: .all).realtimeFactor ?? 0, 4, accuracy: 0.001)
    }

    /// Rewriting has no audio, so there is no such ratio and none is invented.
    @MainActor
    func testRewritingHasNoRealtimeFactor() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "This Mac",
            processingSeconds: 2
        )])
        XCTAssertNil(usage.counters[0].totals(in: .all).realtimeFactor)
    }

    func testAverageAndFactorAreSafeBeforeAnythingHasRun() {
        let empty = UsageDay()
        XCTAssertEqual(empty.secondsPerRun, 0)
        XCTAssertNil(empty.realtimeFactor, "No time spent means no ratio, not a division by zero")
    }

    func testLatencyKeepsThePrecisionThatDistinguishesModels() {
        // Two models a tenth of a second apart must not both read "1s".
        XCTAssertEqual(UsageFormat.latency(1.24), "1.24s")
        XCTAssertEqual(UsageFormat.latency(1.31), "1.31s")
        XCTAssertEqual(UsageFormat.latency(12.4), "12.4s")
        XCTAssertEqual(UsageFormat.latency(75), "1m 15s")
    }

    // MARK: - Per profile

    @MainActor
    func testRewritesAreAlsoGroupedByProfile() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "a", displayName: "A", location: "This Mac",
            tokensIn: 10, processingSeconds: 1, profileID: "cleanup", profileName: "Clean up"
        )])
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "b", displayName: "B", location: "OpenAI",
            tokensIn: 20, processingSeconds: 3, profileID: "cleanup", profileName: "Clean up"
        )])
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "a", displayName: "A", location: "This Mac",
            tokensIn: 5, processingSeconds: 1, profileID: "email", profileName: "Email"
        )])

        XCTAssertEqual(usage.counters.count, 2, "Two models")
        XCTAssertEqual(usage.profileCounters(in: .all).count, 2, "Two profiles")
        let cleanup = usage.profileCounters(in: .all).first { $0.profileID == "cleanup" }
        XCTAssertEqual(cleanup?.totals(in: .all).runs, 2, "A profile spans whichever models served it")
        XCTAssertEqual(cleanup?.totals(in: .all).tokensIn, 30)
        XCTAssertEqual(cleanup?.totals(in: .all).secondsPerRun ?? 0, 2, accuracy: 0.001)
    }

    /// Transcription has no profile, so it must not create a phantom row.
    @MainActor
    func testTranscriptionDoesNotAppearUnderProfiles() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .transcribe, modelID: "p", displayName: "P", location: "This Mac", audioSeconds: 3
        )])
        XCTAssertTrue(usage.profileCounters(in: .all).isEmpty)
    }

    @MainActor
    func testProfilesSurviveARestartAndAreClearedByReset() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = UsageStatistics(storeURL: url)
        first.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "This Mac",
            profileID: "cleanup", profileName: "Clean up"
        )])
        first.flush()

        let second = UsageStatistics(storeURL: url)
        XCTAssertEqual(second.profileCounters(in: .all).count, 1)
        second.reset()
        XCTAssertTrue(second.profileCounters(in: .all).isEmpty, "Reset must clear both views of the same runs")
    }

    // MARK: - Periods

    /// Day keys are compared as strings, so they have to sort chronologically.
    /// Zero-padding is what makes that true, and dropping it would put the
    /// ninth of a month after the tenth.
    func testDayKeysSortChronologically() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func key(_ y: Int, _ m: Int, _ d: Int) -> String {
            UsageDayKey.key(
                for: calendar.date(from: DateComponents(year: y, month: m, day: d))!,
                calendar: calendar
            )
        }
        XCTAssertEqual(key(2026, 9, 5), "2026-09-05")
        XCTAssertLessThan(key(2026, 9, 9), key(2026, 9, 10))
        XCTAssertLessThan(key(2026, 9, 30), key(2026, 10, 1))
        XCTAssertLessThan(key(2025, 12, 31), key(2026, 1, 1))
    }

    /// Seven days means seven calendar days, not 604,800 seconds: a clock
    /// change would otherwise move the boundary by an hour and drop a day.
    func testTheWeekIsSevenCalendarDaysIncludingToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        XCTAssertEqual(UsagePeriod.week.earliestDay(now: now, calendar: calendar), "2026-09-05")
        XCTAssertEqual(UsagePeriod.month.earliestDay(now: now, calendar: calendar), "2026-09-01")
        XCTAssertNil(UsagePeriod.all.earliestDay(now: now, calendar: calendar), "All time excludes nothing")
    }

    /// The point of bucketing by day: a total cannot be filtered back into a
    /// period, so the counters have to keep the days apart.
    @MainActor
    func testAPeriodOnlySumsTheDaysInsideIt() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        // Written straight into the buckets, since `record` can only ever
        // write today and this needs a history.
        usage.replaceForTesting(counters: [
            UsageCounter(
                job: .rewrite, modelID: "m", displayName: "M", location: "This Mac",
                days: [
                    "2026-09-11": UsageDay(runs: 1, tokensIn: 10),
                    "2026-09-02": UsageDay(runs: 1, tokensIn: 100),
                    "2026-08-20": UsageDay(runs: 1, tokensIn: 1000),
                ],
                firstUsed: Date(), lastUsed: Date()
            ),
        ])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let counter = usage.counters[0]

        XCTAssertEqual(counter.totals(in: .week, now: now).tokensIn, 10, "Only the day inside the week")
        XCTAssertEqual(counter.totals(in: .month, now: now).tokensIn, 110, "Both September days")
        XCTAssertEqual(counter.totals(in: .all, now: now).tokensIn, 1110, "Every day there is")
        XCTAssertEqual(counter.totals(in: .all, now: now).runs, 3)
    }

    /// A model that did nothing in the chosen period is not listed at all,
    /// rather than shown as a row of zeros.
    @MainActor
    func testAModelIdleInThePeriodIsNotListed() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.replaceForTesting(counters: [
            UsageCounter(
                job: .rewrite, modelID: "old", displayName: "Old", location: "This Mac",
                days: ["2020-01-01": UsageDay(runs: 1, tokensIn: 5)],
                firstUsed: Date(), lastUsed: Date()
            ),
        ])
        XCTAssertTrue(usage.counters(for: .rewrite, in: .week).isEmpty)
        XCTAssertEqual(usage.counters(for: .rewrite, in: .all).count, 1)
    }

    /// Dictations and words typed belong to the dictation, not to any model:
    /// one dictation that used two models is one dictation.
    @MainActor
    func testDictationsAreCountedOncePerDictationNotPerModel() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([
            UsageMeasurement(job: .transcribe, modelID: "p", displayName: "P", location: "This Mac",
                             tokensOut: 12, audioSeconds: 5),
            UsageMeasurement(job: .rewrite, modelID: "q", displayName: "Q", location: "This Mac",
                             tokensIn: 30, tokensOut: 12),
        ], wordsTyped: 9)

        let summary = usage.summary(in: .all)
        XCTAssertEqual(summary.runs, 1, "Two models, one dictation")
        XCTAssertEqual(summary.wordsTyped, 9)
        // The headline totals do span both jobs, which is the one place adding
        // them up is the right thing to do.
        XCTAssertEqual(summary.tokensIn, 30)
        XCTAssertEqual(summary.tokensOut, 24)
    }

    // MARK: - Words, which is what a bare number is read as

    func testWordsAreCountedTheWayAPersonWouldCountThem() {
        XCTAssertEqual(UsageMeasurement.words(in: "one two three"), 3)
        XCTAssertEqual(UsageMeasurement.words(in: ""), 0)
        XCTAssertEqual(UsageMeasurement.words(in: "   spaced   out   "), 2)
        XCTAssertEqual(UsageMeasurement.words(in: "across\nlines\n\nhere"), 3)
    }

    /// The estimate is derived from the same word count that is displayed, so
    /// the two can never tell different stories about the same text.
    func testTheEstimateAgreesWithTheDisplayedWordCount() {
        let text = "a sentence of exactly seven words here"
        let words = UsageMeasurement.words(in: text)
        XCTAssertEqual(words, 7)
        XCTAssertEqual(UsageMeasurement.estimatedTokens(in: text), Int((7.0 * 4 / 3).rounded()))
    }

    @MainActor
    func testWordsAccumulateAlongsideTokens() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "OpenAI",
            tokensIn: 130, tokensOut: 52, wordsIn: 100, wordsOut: 40
        )])
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "m", displayName: "M", location: "OpenAI",
            tokensIn: 13, tokensOut: 5, wordsIn: 10, wordsOut: 4
        )])
        let totals = usage.counters[0].totals(in: .all)
        XCTAssertEqual(totals.wordsIn, 110)
        XCTAssertEqual(totals.wordsOut, 44)
        XCTAssertEqual(totals.tokensIn, 143, "Tokens stay, because that is what a provider bills")
        XCTAssertEqual(totals.tokensOut, 57)
    }

    /// Transcription consumes audio, so it reads no words. The figure at the
    /// top must not imply otherwise.
    @MainActor
    func testTranscriptionProducesWordsButConsumesNone() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .transcribe, modelID: "p", displayName: "P", location: "This Mac",
            tokensOut: 14, wordsOut: 11, audioSeconds: 6
        )], wordsTyped: 11)
        let summary = usage.summary(in: .all)
        XCTAssertEqual(summary.wordsIn, 0, "Audio is not words")
        XCTAssertEqual(summary.wordsOut, 11)
    }

    // MARK: - What the review found

    /// A model id is only unique within the place that served it. Two custom
    /// endpoints offering the same alias are two different models, and their
    /// speed is the whole reason to tell them apart.
    @MainActor
    func testTheSameModelNameAtTwoPlacesStaysTwoRows() {
        let (usage, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "llama3", displayName: "llama3",
            location: "work.example", tokensIn: 10, processingSeconds: 1
        )])
        usage.record([UsageMeasurement(
            job: .rewrite, modelID: "llama3", displayName: "llama3",
            location: "home.example", tokensIn: 90, processingSeconds: 9
        )])
        XCTAssertEqual(usage.counters.count, 2)
        XCTAssertEqual(Set(usage.counters.map(\.location)), ["work.example", "home.example"])
        XCTAssertEqual(Set(usage.counters.map(\.id)).count, 2, "Rows must not share an identity")
    }

    /// Day keys are a permanent record; the user's calendar is a display
    /// preference they can change. Read through a Chinese calendar, two dates a
    /// month apart produced the same key and merged their months.
    func testDayKeysIgnoreTheUsersCalendarSystem() {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Europe/Berlin")!

        let june = gregorian.date(from: DateComponents(year: 2025, month: 6, day: 25))!
        let july = gregorian.date(from: DateComponents(year: 2025, month: 7, day: 25))!

        XCTAssertEqual(UsageDayKey.key(for: june, calendar: chinese), "2025-06-25")
        XCTAssertEqual(UsageDayKey.key(for: july, calendar: chinese), "2025-07-25")
        XCTAssertNotEqual(
            UsageDayKey.key(for: june, calendar: chinese),
            UsageDayKey.key(for: july, calendar: chinese),
            "Two different months must never share a key"
        )
    }

    /// "This month" has to mean the month the keys are written in, or a period
    /// can exclude the very days it should contain.
    func testThisMonthAgreesWithTheKeysItFilters() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 11))!

        XCTAssertEqual(UsagePeriod.month.earliestDay(now: now, calendar: buddhist), "2026-09-01")
        let today = UsageDayKey.key(for: now, calendar: buddhist)
        XCTAssertGreaterThanOrEqual(
            today, UsagePeriod.month.earliestDay(now: now, calendar: buddhist)!,
            "Today must fall inside this month"
        )
    }
}
