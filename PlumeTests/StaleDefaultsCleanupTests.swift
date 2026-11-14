import Foundation
import Testing
@testable import Plume

/// The cleanup deletes only address-named frame keys and retired keys, moves
/// the newest-shaped old main-window frames to the stable keys when those are
/// empty, and runs once per domain.
struct StaleDefaultsCleanupTests {
    private static let newestStem = "SwiftUI.WindowGroup<SwiftUI.ModifiedContent<Plume.MainWindow, Plume.(unknown context at $10645bc20).AccentTintModifier>>-1-AppWindow-1"
    private static let olderStem = "SwiftUI.ModifiedContent<Plume.MainWindow, Plume.(unknown context at $10503955c).AccentTintModifier>-1-AppWindow-1"

    private static let newestWindowKey = "NSWindow Frame " + newestStem
    private static let newestSplitKey = "NSSplitView Subview Frames " + newestStem + ", SidebarNavigationSplitView"
    private static let olderWindowKey = "NSWindow Frame " + olderStem
    private static let olderSplitKey = "NSSplitView Subview Frames " + olderStem + ", SidebarNavigationSplitView"

    private static let keptKeys = [
        StaleDefaultsCleanup.mainWindowFrameKey,
        StaleDefaultsCleanup.mainSplitViewFramesKey,
        "NSWindow Frame com_apple_SwiftUI_Settings_window",
        "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView",
        "NSWindow Frame Plume.MainWindow-1-AppWindow-1",
        "NSWindow Frame SUUpdateAlert2",
        "lastSelectedTaskID",
    ]

    private let suiteName = "StaleDefaultsCleanupTests-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func runNow(_ defaults: UserDefaults) {
        StaleDefaultsCleanup.runOnce(suiteName: suiteName, removal: { $0() })
    }

    @Test func matcherTakesOnlyAddressNamedFrameKeys() {
        let stale = [Self.newestWindowKey, Self.newestSplitKey, Self.olderWindowKey, Self.olderSplitKey]
        #expect(Set(StaleDefaultsCleanup.staleKeys(in: stale + Self.keptKeys)) == Set(stale))
    }

    @Test func removesStaleAndRetiredKeysAndKeepsTheRest() {
        let defaults = makeDefaults()
        for key in [Self.newestWindowKey, Self.newestSplitKey, Self.olderWindowKey, Self.olderSplitKey] + Self.keptKeys {
            defaults.set("value", forKey: key)
        }
        defaults.set("A1B2", forKey: "lastOpenTaskID")

        runNow(defaults)

        for key in [Self.newestWindowKey, Self.newestSplitKey, Self.olderWindowKey, Self.olderSplitKey, "lastOpenTaskID"] {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
        for key in Self.keptKeys {
            #expect(defaults.string(forKey: key) == "value", "\(key)")
        }
    }

    @Test func carriesTheNewestShapedFramesOverWhenTheStableKeysAreEmpty() {
        let defaults = makeDefaults()
        defaults.set("1 2 3 4 0 0 1728 1084 ", forKey: Self.newestWindowKey)
        defaults.set(["newest split"], forKey: Self.newestSplitKey)
        defaults.set("9 9 9 9 0 0 2560 1410 ", forKey: Self.olderWindowKey)
        defaults.set(["older split"], forKey: Self.olderSplitKey)

        runNow(defaults)

        #expect(defaults.string(forKey: StaleDefaultsCleanup.mainWindowFrameKey) == "1 2 3 4 0 0 1728 1084 ")
        #expect(defaults.stringArray(forKey: StaleDefaultsCleanup.mainSplitViewFramesKey) == ["newest split"])
    }

    @Test func leavesStableKeysThatAlreadyHaveValues() {
        let defaults = makeDefaults()
        defaults.set("1 2 3 4 0 0 1728 1084 ", forKey: Self.newestWindowKey)
        defaults.set(["newest split"], forKey: Self.newestSplitKey)
        defaults.set("current frame", forKey: StaleDefaultsCleanup.mainWindowFrameKey)
        defaults.set(["current split"], forKey: StaleDefaultsCleanup.mainSplitViewFramesKey)

        runNow(defaults)

        #expect(defaults.string(forKey: StaleDefaultsCleanup.mainWindowFrameKey) == "current frame")
        #expect(defaults.stringArray(forKey: StaleDefaultsCleanup.mainSplitViewFramesKey) == ["current split"])
    }

    @Test func runsOncePerDomain() {
        let defaults = makeDefaults()
        runNow(defaults)
        #expect(defaults.integer(forKey: StaleDefaultsCleanup.versionKey) == StaleDefaultsCleanup.version)

        defaults.set("value", forKey: Self.newestWindowKey)
        defaults.set("A1B2", forKey: "lastOpenTaskID")
        runNow(defaults)

        #expect(defaults.string(forKey: Self.newestWindowKey) == "value")
        #expect(defaults.string(forKey: "lastOpenTaskID") == "A1B2")
        #expect(defaults.object(forKey: StaleDefaultsCleanup.mainWindowFrameKey) == nil)
    }
}
