import AppKit

/// Confirms quitting while an agent is still working, since terminating kills
/// every PTY child outright — there is no graceful shutdown to wait for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusEngine: StatusEngine = .shared

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.shouldConfirmQuit(statuses: statusEngine.tabStatuses.values) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit While Agents Are Working?"
        alert.informativeText =
            "One or more tasks have an agent still working or waiting on you. " +
            "Quitting now ends those processes without saving any in-progress response."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Split out for testing: true when any tab is still working or needs
    /// the user's attention.
    static func shouldConfirmQuit(statuses: some Sequence<TaskStatus>) -> Bool {
        statuses.contains { $0 == .working || $0 == .needsInput }
    }
}
