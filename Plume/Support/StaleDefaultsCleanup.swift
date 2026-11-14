import Foundation

/// Removes user defaults keys nothing reads any more, once per domain.
///
/// Before the main window had a scene id, SwiftUI named its saved frames after
/// the content's type, which spells a private modifier by its load address.
/// Every build added a new pair, and every write to user defaults costs time
/// in proportion to the domain's key count. The newest-shaped old frame moves
/// to the stable key first, so the window opens where it was.
nonisolated enum StaleDefaultsCleanup {
    static let versionKey = "staleDefaultsCleanupVersion"
    static let version = 1

    static let mainWindowFrameKey = "NSWindow Frame main-AppWindow-1"
    static let mainSplitViewFramesKey = "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"

    static let retiredKeys = ["lastOpenTaskID"]

    private static let windowFramePrefix = "NSWindow Frame "
    private static let splitViewFramesPrefix = "NSSplitView Subview Frames "
    private static let splitViewSuffix = ", SidebarNavigationSplitView"
    private static let mainWindowSuffix = "-1-AppWindow-1"
    private static let newestContentPrefix = "SwiftUI.WindowGroup<SwiftUI.ModifiedContent<Plume.MainWindow, "

    /// Carries the frames over before returning, so call it before SwiftUI
    /// opens the main window. `suiteName` nil means the app's own domain.
    ///
    /// The removal is one `CFPreferencesSetMultiple` on `removal`: 0.3 s for
    /// 3,700 keys, where a `removeObject` per key took 1.4 s and posted a change
    /// notification for each. It names only the keys it removes, so a
    /// concurrent write to any other key survives.
    static func runOnce(
        suiteName: String? = nil,
        removal: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }
    ) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        #if !DEBUG
        guard defaults.integer(forKey: versionKey) < version else { return }
        #endif
        let stale = staleKeys(in: defaults.dictionaryRepresentation().keys)
        carryOverMainWindowFrames(from: stale, in: defaults)

        let doomed = stale + retiredKeys
        let applicationID = suiteName ?? Bundle.main.bundleIdentifier
        removal {
            CFPreferencesSetMultiple(
                [versionKey: version] as CFDictionary,
                doomed as CFArray,
                (applicationID as CFString?) ?? kCFPreferencesCurrentApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            // The first read after the change rebuilds the in-process cache,
            // about 0.2 s here; take it here rather than on the main thread.
            _ = (suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard).object(forKey: versionKey)
        }
    }

    static func staleKeys(in keys: some Sequence<String>) -> [String] {
        keys.filter(isStale)
    }

    /// A frame key named after a SwiftUI type that spells a private type by its
    /// address.
    static func isStale(_ key: String) -> Bool {
        guard key.hasPrefix(windowFramePrefix + "SwiftUI.") || key.hasPrefix(splitViewFramesPrefix + "SwiftUI."),
              key.contains("(unknown context at $") else { return false }
        let name = key.hasSuffix(splitViewSuffix) ? key.dropLast(splitViewSuffix.count) : Substring(key)
        guard let marker = name.range(of: "-1-AppWindow-", options: .backwards) else { return false }
        let windowNumber = name[marker.upperBound...]
        return !windowNumber.isEmpty && windowNumber.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func carryOverMainWindowFrames(from staleKeys: [String], in defaults: UserDefaults) {
        // A domain records no write times, so the newest content shape stands
        // in for the newest build, and the key order only makes it repeatable.
        let windowKeys = staleKeys
            .filter { $0.hasPrefix(windowFramePrefix) && $0.hasSuffix(mainWindowSuffix) }
            .sorted()
        let preferred = windowKeys.last { $0.dropFirst(windowFramePrefix.count).hasPrefix(newestContentPrefix) }
        guard let windowKey = preferred ?? windowKeys.last else { return }

        let stem = windowKey.dropFirst(windowFramePrefix.count)
        copy(from: windowKey, to: mainWindowFrameKey, in: defaults)
        copy(from: splitViewFramesPrefix + stem + splitViewSuffix, to: mainSplitViewFramesKey, in: defaults)
    }

    private static func copy(from oldKey: String, to newKey: String, in defaults: UserDefaults) {
        guard defaults.object(forKey: newKey) == nil, let value = defaults.object(forKey: oldKey) else { return }
        defaults.set(value, forKey: newKey)
    }
}
