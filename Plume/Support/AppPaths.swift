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

    static func createDirectories() throws {
        for directory in [applicationSupport, hooksDirectory, eventsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
