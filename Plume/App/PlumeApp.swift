import SwiftUI
import SwiftData

@main
struct PlumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let modelContainer: ModelContainer = {
        let schema = Schema([TaskGroup.self, WorkTask.self, TaskTab.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        GhosttyRuntime.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
        }
        .modelContainer(modelContainer)
        .commands {
            PlumeCommands()
        }
    }
}
