import os
import SwiftUI
import SwiftData

@main
struct PlumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let modelContainer: ModelContainer = makeModelContainer()

    init() {
        BundledFonts.registerIfNeeded()
        GhosttyRuntime.shared.start()
        PullRequestStore.shared.resolveIgnoredPendingChecks = { repository in
            let setting = await MainActor.run { AppSettings.shared.ignoredPendingChecks }
            return await GitService.shared.ignoredPendingChecks(
                in: repository,
                plumeSetting: setting
            )
        }
    }

    /// Opens the store, and on failure moves it aside and starts empty rather
    /// than leaving an installed app that cannot launch. Losing the data beats
    /// having no way in; the moved-aside file keeps it recoverable by hand.
    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([TaskGroup.self, WorkTask.self, TaskTab.self])
        let configuration = ModelConfiguration(schema: schema, url: AppPaths.storeFile)

        do {
            try AppPaths.createDirectories()
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            Log.app.error("Could not open store, moving it aside: \(error, privacy: .public)")
        }

        archiveStore()

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer with an empty store: \(error)")
        }
    }

    /// SQLite keeps its write-ahead log and shared memory beside the store, so
    /// leaving them behind would corrupt the fresh one.
    private static func archiveStore() {
        let store = AppPaths.storeFile
        let suffix = ".\(Int(Date.now.timeIntervalSince1970)).bak"

        for path in [store.path, store.path + "-shm", store.path + "-wal"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try FileManager.default.moveItem(atPath: path, toPath: path + suffix)
            } catch {
                Log.app.error("Could not move \(path, privacy: .public) aside: \(error, privacy: .public)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .modelContainer(modelContainer)
        .commands {
            PlumeCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
