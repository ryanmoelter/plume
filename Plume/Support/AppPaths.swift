import Foundation

enum AppPaths {
    static var applicationSupport: URL {
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

    /// Generated statusline capture script, chained ahead of the user's own.
    static var statuslineScriptFile: URL {
        hooksDirectory.appending(path: "statusline.sh")
    }

    /// Captured statusline payload, written atomically as `<taskID>/<tabID>.statusline.json`.
    static func statuslineFile(taskID: UUID, tabID: UUID) -> URL {
        eventsDirectory
            .appending(path: taskID.uuidString)
            .appending(path: "\(tabID.uuidString).statusline.json")
    }

    static func createDirectories() throws {
        for directory in [applicationSupport, hooksDirectory, eventsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
