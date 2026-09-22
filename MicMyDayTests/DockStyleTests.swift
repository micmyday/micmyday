import SwiftUI
import XCTest
@testable import MicMyDay

/// The Dock's selectable designs.
///
/// Each one is a row in a catalogue rather than code, and a missing row falls
/// back to the themed surface rather than failing to build — which is the
/// right behaviour at runtime and the wrong thing to discover by eye. So the
/// test is that every case the picker offers actually has a design behind it.
final class DockStyleTests: XCTestCase {
    /// A style whose row is missing would silently draw as `theme`, and the
    /// picker would show two identical swatches under different names.
    @MainActor
    func testEveryStyleHasADesignOfItsOwn() {
        for style in DockStyle.allCases where style != .theme {
            XCTAssertNotNil(
                DockSurface.catalogue[style],
                "\(style.title) is offered in the picker with no design behind it"
            )
        }
    }

    /// The whole point of the picker: eighteen swatches that look like
    /// eighteen different things.
    func testTheNamesAreDistinctAndSaySomething() {
        let titles = DockStyle.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for style in DockStyle.allCases {
            XCTAssertFalse(style.title.isEmpty)
            XCTAssertFalse(style.detail.isEmpty, "\(style.title) has nothing to say to VoiceOver")
        }
    }

    /// `theme` is the one design that is not a design: it reads the palette,
    /// so the live colour the indicator is carrying has to reach it. Every
    /// other style states its own colours and must ignore the argument, or
    /// choosing one would still leave the overlay following the theme.
    @MainActor
    func testOnlyTheThemedSurfaceFollowsTheIndicatorsTint() {
        XCTAssertEqual(DockStyle.theme.surface(tint: .red).stopFill, Color.red)
        XCTAssertEqual(DockStyle.theme.surface(tint: .green).stopFill, Color.green)

        let first = DockStyle.island.surface(tint: .red).stopFill
        let second = DockStyle.island.surface(tint: .green).stopFill
        XCTAssertEqual(first, second)
    }

    /// An existing install has no stored choice, and must not wake up wearing
    /// a design it never picked.
    @MainActor
    func testTheDefaultIsTheAppsOwnTheme() {
        let name = "DockStyleTests.default"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }

        let fresh = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "DockStyleTests.\(UUID().uuidString)")
        )
        XCTAssertEqual(fresh.overlayDockStyle, .theme)

        defaults.set("iris", forKey: "overlayDockStyle")
        let returning = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "DockStyleTests.\(UUID().uuidString)")
        )
        XCTAssertEqual(returning.overlayDockStyle, .iris)
    }

    /// A design that was removed, or a defaults file written by a newer build,
    /// must land on something that draws rather than leaving the overlay with
    /// no surface at all.
    @MainActor
    func testAnUnknownStoredDesignFallsBackToTheTheme() {
        let name = "DockStyleTests.unknown"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("nebula", forKey: "overlayDockStyle")

        let settings = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: "DockStyleTests.\(UUID().uuidString)")
        )
        XCTAssertEqual(settings.overlayDockStyle, .theme)
    }
}
