import Foundation

enum AppPaths {
    /// `Plume.debug` for the debug build, whose bundle ID carries that
    /// suffix, and `Plume` otherwise — so a debug run never writes the store,
    /// hooks and events the installed app reads.
    static let debugBundleSuffix = ".debug"

    static func directoryName(forBundleID bundleID: String?) -> String {
        guard let bundleID, bundleID.hasSuffix(debugBundleSuffix) else { return "Plume" }
        return "Plume.debug"
    }

    static var directoryName: String {
        directoryName(forBundleID: Bundle.main.bundleIdentifier)
    }

    static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: directoryName)
    }

    /// Always `Plume`, never `Plume.debug`. `~/.claude/settings.json` is global
    /// and its `statusLine` holds a single command, so a per-build script path
    /// would have a debug and a release install overwrite each other.
    static var sharedApplicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: "Plume")
    }

    /// SwiftData's persistent store.
    static var storeFile: URL {
        applicationSupport.appending(path: "Plume.store")
    }

    /// Generated `settings.json` passed to `claude --settings`.
    static var hooksDirectory: URL {
        applicationSupport.appending(path: "hooks")
    }

    static var hookSettingsFile: URL {
        hooksDirectory.appending(path: "settings.json")
    }

    /// Hook events land here as `<taskID>/<tabID>.jsonl`.
    static var eventsDirectory: URL {
        applicationSupport.appending(path: "events")
    }

    static func eventsFile(taskID: UUID, tabID: UUID) -> URL {
        eventsDirectory
            .appending(path: taskID.uuidString)
            .appending(path: "\(tabID.uuidString).jsonl")
    }

    /// The statusline capture script earlier versions generated and installed
    /// into `~/.claude/settings.json`. Kept so `StatuslineUninstall` can
    /// recognize and remove that installation.
    static var statuslineScriptFile: URL {
        sharedApplicationSupport.appending(path: "hooks").appending(path: "statusline.sh")
    }

    static func createDirectories() throws {
        for directory in [applicationSupport, hooksDirectory, eventsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
