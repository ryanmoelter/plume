import AppKit

/// Confirms quitting while an agent is still working, since terminating kills
/// every PTY child outright — there is no graceful shutdown to wait for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusEngine: StatusEngine = .shared
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The WindowGroup's NSWindow doesn't exist yet at delegate-init time;
        // it's up by the time launch finishes.
        guard let window = NSApp.windows.first else { return }
        tintTitlebar(of: window)

        // `effectiveAppearance` KVO fires on both a system light/dark switch
        // and window-level appearance changes, so one observer covers both.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self, weak window] _, _ in
            guard let self, let window else { return }
            self.tintTitlebar(of: window)
        }
    }

    /// Transparent titlebar plus an explicit background color makes the
    /// titlebar read as part of the tinted window instead of a separate gray
    /// strip. Leaving `styleMask` untouched (no `.fullSizeContentView`) keeps
    /// the traffic lights and content layout exactly where AppKit already
    /// puts them.
    private func tintTitlebar(of window: NSWindow) {
        let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let tint = ThemeChrome.titlebarBackground(forDark: isDark) else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = nil
            return
        }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = tint
    }

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
