import Foundation

/// What the app is entitled to do right now.
///
/// Deliberately a small, total enum rather than a pile of booleans: every place
/// that gates on licensing switches over this, so a new state cannot be added
/// without the compiler pointing at everywhere that has to consider it.
enum LicenseState: Equatable {
    /// Inside the free trial, with this many whole days left.
    case trial(daysRemaining: Int)
    /// A key has been validated and activated for this machine.
    case licensed
    /// The trial has run out and no key has been entered.
    case expired
    /// A key is entered but the last check failed and the offline grace period
    /// has run out. Treated as unlicensed for gating, but says something
    /// different to the user, because the difference matters to them.
    case needsRevalidation

    var allowsDictation: Bool {
        switch self {
        case .trial, .licensed: return true
        case .expired, .needsRevalidation: return false
        }
    }

    /// The line shown in the menu bar panel and Settings when dictation is off.
    var blockedReason: String? {
        switch self {
        case .trial, .licensed:
            return nil
        case .expired:
            return "Your trial has ended. Enter a licence key to keep dictating."
        case .needsRevalidation:
            return "MicMyDay could not check your licence. Connect to the internet once to continue."
        }
    }
}

/// How long the trial lasts and how long a licensed copy may go unverified.
enum LicenseTerms {
    /// What the website promises, which is the number that matters: somebody
    /// who read "free for 14 days" and was stopped on the seventh would be
    /// right to say so in public, and right that it was not what they were
    /// told.
    ///
    /// The same fourteen as `offlineGraceDays` below by coincidence, not by
    /// design. They answer different questions — how long an unlicensed copy
    /// runs, and how long a licensed one runs unverified — and either can move
    /// without the other.
    static let trialDays = 14

    /// A licensed copy keeps working this long without reaching Polar. Long
    /// enough to cover a holiday off the network, short enough that a refunded
    /// or deactivated key does not work forever.
    static let offlineGraceDays = 14

    /// How often a working copy re-checks in the background. Well inside the
    /// grace period, so a machine that is online now and then never notices.
    static let revalidateEvery: TimeInterval = 60 * 60 * 24 * 3
}
