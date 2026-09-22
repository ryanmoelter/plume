import AppKit
import os

/// Confirms quitting while an agent is still working, since terminating kills
/// every PTY child outright — there is no graceful shutdown to wait for.
///
/// A system-initiated quit (logout, restart, shutdown) is distinguished from
/// a user-initiated one (⌘Q, Quit menu item) because `AppSettings` lets each
/// be confirmed independently — the system case defaults off, since AppKit
/// blocks the OS's own shutdown sequence on `applicationShouldTerminate`'s
/// return, and `NSAlert.runModal()` can wait indefinitely for a user who may
/// not be at the machine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusEngine: StatusEngine = .shared
    var settings: AppSettings = .shared

    /// Latched by `NSWorkspace.willPowerOffNotification`, which fires ahead
    /// of the logout/restart/shutdown Apple Event in some cases. Kept as a
    /// belt-and-suspenders alongside the Apple Event's quit reason, which is
    /// the primary signal.
    private var isPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        // One `git` call per remembered folder, so it stays off the main
        // thread; nothing on screen reads the list before it settles.
        Task.detached(priority: .utility) {
            RecentFolders.migrateWorktreesToProjectsOnce()
        }

        // App-lifetime, so it cannot leak or double-install the way a
        // per-tab monitor would across tab and task switches.
        TerminalShortcutMonitor.shared.install()

        startApplyingShortcutBindings()

        #if DEBUG
        LinkClickHarness.runIfRequested()
        ControlServer.shared.startIfEnabled()
        #endif

        AppAppearance.apply(AppAppearance.decision())

        // The WindowGroup's NSWindow doesn't exist yet at delegate-init time;
        // it's up by the time launch finishes.
        guard let window = NSApp.windows.first else { return }
        tintTitlebar(of: window)
    }

    @objc private func handleWillPowerOff() {
        isPoweringOff = true
    }

    /// Keeps the menu's rebindable chords in step with the setting, for as
    /// long as the app runs. `ShortcutMenuApplier` documents why the menu
    /// SwiftUI built cannot be left to update itself.
    ///
    /// The first pass waits for the main menu, which SwiftUI installs after
    /// this delegate callback returns.
    private func startApplyingShortcutBindings() {
        Task { @MainActor in
            while NSApp.mainMenu == nil, !Task.isCancelled {
                await Task.yield()
            }
            for await bindings in settings.shortcutBindingsStream {
                guard let menu = NSApp.mainMenu else { continue }
                ShortcutMenuApplier.apply(bindings, to: menu)
            }
        }
    }

    /// Transparent titlebar plus an explicit background color makes the
    /// titlebar read as part of the tinted window instead of a separate gray
    /// strip. Leaving `styleMask` untouched (no `.fullSizeContentView`) keeps
    /// the traffic lights and content layout exactly where AppKit already
    /// puts them.
    ///
    /// Applied once: the tint resolves its own light/dark variant per draw.
    private func tintTitlebar(of window: NSWindow) {
        guard let tint = ThemeChrome.titlebarBackground() else {
            window.titlebarAppearsTransparent = false
            window.backgroundColor = nil
            return
        }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = tint
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shouldConfirm = Self.shouldConfirmQuit(
            statuses: statusEngine.tabStatuses.values,
            isSystemInitiated: isSystemInitiatedQuit,
            confirmUserQuit: settings.confirmQuitWhileWorking,
            confirmSystemQuit: settings.confirmSystemInitiatedQuit
        )
        guard shouldConfirm else {
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

    /// Headless agents are children of this process, and closing their stdin
    /// is what tells them to exit. Without this they outlive the app until
    /// they notice the pipe has gone.
    func applicationWillTerminate(_ notification: Notification) {
        // Logged because its *absence* is the interesting case: AppKit skips
        // this path when the process is signalled rather than quit, and an
        // agent that outlives the app goes on writing a transcript the next
        // run resumes from.
        Log.app.info("Terminating, closing \(HeadlessSessionManager.shared.activeSessionCount, privacy: .public) agent session(s)")
        HeadlessSessionManager.shared.closeAll()
        KeepAwakeCoordinator.shared.releaseForTermination()
        #if DEBUG
        ControlServer.shared.stop()
        #endif
    }

    /// True when the current terminate request originated from the OS
    /// (logout, restart, shutdown) rather than ⌘Q or the Quit menu item.
    ///
    /// The system sends `applicationShouldTerminate` inside a `kAEQuitApplication`
    /// Apple Event carrying a `kAEQuitReason` parameter (`kAELogOut`,
    /// `kAEShowRestartDialog`, `kAEShowShutdownDialog`, `kAERestart`,
    /// `kAEShutDown`, `kAEReallyLogOut`); a plain ⌘Q has no such parameter.
    /// `willPowerOffNotification` is a corroborating latch for cases where it
    /// fires before the event is checked.
    private var isSystemInitiatedQuit: Bool {
        if isPoweringOff { return true }
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass,
            event.eventID == kAEQuitApplication
        else {
            return false
        }
        return event.paramDescriptor(forKeyword: kAEQuitReason) != nil
    }

    /// Split out for testing: true when any tab is still working or needs
    /// the user's attention, and the setting for this quit's origin
    /// (user-initiated vs. system-initiated) has confirmation turned on.
    static func shouldConfirmQuit(
        statuses: some Sequence<TaskStatus>,
        isSystemInitiated: Bool,
        confirmUserQuit: Bool,
        confirmSystemQuit: Bool
    ) -> Bool {
        let confirmationEnabled = isSystemInitiated ? confirmSystemQuit : confirmUserQuit
        guard confirmationEnabled else { return false }
        return statuses.contains { $0 == .working || $0.wantsAttention }
    }
}
