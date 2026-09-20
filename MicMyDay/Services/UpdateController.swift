import Sparkle
import SwiftUI

/// In-app updates, for the direct download build.
///
/// MicMyDay is distributed as a notarised DMG rather than through the App
/// Store, so there is nothing to ship a fix through unless the app can update
/// itself. Sparkle checks a signed appcast, and refuses any download whose
/// EdDSA signature does not match the public key in Info.plist, so a
/// substituted file cannot be installed even though the feed is plain XML over
/// a URL.
@MainActor
final class UpdateController: ObservableObject {
    /// Whether a check started by the user is in flight, so the menu item can
    /// say so rather than appearing to do nothing.
    @Published private(set) var canCheck = true
    /// Mirrors Sparkle's own setting so a view can bind to it directly. Sparkle
    /// stores the real value; this exists so SwiftUI has something observable
    /// to watch, because a computed property cannot be bound to.
    @Published var automaticallyChecks: Bool = true {
        didSet {
            guard automaticallyChecks != updater.automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private let updater: SPUUpdater
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        // A build made from source updates by pulling and rebuilding, so the
        // updater is never started for one: it would offer to replace a copy
        // the user compiled with one they did not, from a feed describing a
        // different binary entirely.
        #if LOCAL_BUILD
        let startsUpdater = false
        #else
        let startsUpdater = true
        #endif
        // `startingUpdater: true` here rather than in a lazy path: the schedule
        // only runs while the updater is started, and a menu-bar app that is
        // never "opened" would otherwise check for updates only when the user
        // remembered to ask.
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// The user asked, so show the result either way, including "you are up to
    /// date". A background check stays silent unless there is something to say.
    func checkForUpdates() {
        guard !LicenseManager.isLocalBuild else { return }
        updater.checkForUpdates()
    }

    /// False for a build made from source, where updating means `git pull`.
    nonisolated static var updatesItself: Bool { !LicenseManager.isLocalBuild }

    /// The version this build reports, for the Settings row.
    static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}


