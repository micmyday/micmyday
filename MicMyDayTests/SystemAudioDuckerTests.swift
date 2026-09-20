import XCTest
@testable import MicMyDay

/// The shape of the dip at the start of a recording, and the decision about
/// putting the volume back afterwards.
///
/// Both are pure arithmetic, deliberately kept separate from the Core Audio
/// calls around them, because the thing that matters here cannot be tried out
/// safely: leaving somebody's volume turned down is the worst thing this class
/// can do, and it is not a failure that announces itself.
final class SystemAudioDuckerTests: XCTestCase {
    /// The shipping step count. The curve is parameterised, so the shape
    /// assertions below hold at any resolution; this is the one that runs.
    private let steps = 6

    func testTheFadeStartsAtFullVolumeAndEndsNextToSilence() {
        XCTAssertEqual(SystemAudioDucker.fadeOutFraction(step: 0, of: steps), 1, accuracy: 0.001)
        // The exponential never reaches zero itself; `duck` writes the exact
        // zero after the last step. The curve's job is to be almost there.
        XCTAssertEqual(SystemAudioDucker.fadeOutFraction(step: steps, of: steps), 0.01, accuracy: 0.001)
    }

    func testTheFadeOnlyEverDescends() {
        var previous = Float(2)
        for step in 0 ... steps {
            let value = SystemAudioDucker.fadeOutFraction(step: step, of: steps)
            XCTAssertLessThan(value, previous, "step \(step) did not continue downwards")
            XCTAssertGreaterThan(value, 0, "step \(step) reached silence early")
            previous = value
        }
    }

    /// The point of the curve. The previous shape held the level up early and
    /// dropped late, so the duck was heard long after it had started; this one
    /// is audibly quieter from the very first step.
    func testTheFadeIsAudibleFromTheFirstStep() {
        let first = SystemAudioDucker.fadeOutFraction(step: 1, of: steps)
        XCTAssertLessThan(first, 0.75, "the first step is not yet a heard change")
        XCTAssertGreaterThan(first, 0.4, "the first step is an abrupt cut, not a fade")
    }

    /// Equal steps should be heard as equal steps, which for level means each
    /// one falls by the same factor as the one before.
    func testEveryStepFallsByTheSameFactor() {
        let expected = SystemAudioDucker.fadeOutFraction(step: 1, of: steps)
        for step in 1 ..< steps {
            let ratio = SystemAudioDucker.fadeOutFraction(step: step + 1, of: steps)
                / SystemAudioDucker.fadeOutFraction(step: step, of: steps)
            XCTAssertEqual(ratio, expected, accuracy: 0.001, "step \(step + 1) broke the ratio")
        }
    }

    // MARK: - Putting it back

    func testAFinishedFadeIsRestored() {
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0, weLeftItAt: 0, original: 0.8),
            .jumpThenRamp
        )
    }

    /// The case a slower fade introduced: a dictation short enough to end part
    /// way down. The old test asked whether the volume was below half the
    /// original, so this would have been read as the user reaching for the
    /// keyboard, and the volume would have been left down.
    func testAFadeStoppedPartWayDownIsStillRestored() {
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0.6, weLeftItAt: 0.6, original: 0.8),
            .jumpThenRamp,
            "A dictation that ended mid-dip must still get the volume back"
        )
    }

    func testAVolumeTheUserMovedIsLeftAlone() {
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0.9, weLeftItAt: 0.1, original: 0.8),
            .leaveAlone
        )
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0, weLeftItAt: 0.6, original: 0.8),
            .leaveAlone,
            "Turned down further by hand is still the user's choice"
        )
    }

    /// Reading a volume back does not always return the exact float written.
    func testASmallDifferenceIsTreatedAsOurOwn() {
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0.62, weLeftItAt: 0.6, original: 0.8),
            .jumpThenRamp
        )
    }

    /// A two-word dictation is over before the dip has begun. Ramping back from
    /// a level never reached would add the dip that did not happen.
    func testARecordingShorterThanTheFadeNeedsNoRamp() {
        XCTAssertEqual(
            SystemAudioDucker.restoration(now: 0.8, weLeftItAt: 0.8, original: 0.8),
            .setDirectly
        )
    }
}
