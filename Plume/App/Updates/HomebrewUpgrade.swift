import AppKit
import os

/// Runs the Homebrew upgrade in Terminal.app rather than inside Plume: the
/// cask's `uninstall quit:` makes brew quit Plume mid-upgrade, which would
/// kill a child process, and its `launchctl` step for the sleep helper can
/// ask for a sudo password that only a visible terminal can answer.
enum HomebrewUpgrade {
    /// Set when the user agrees to stop working agents for the upgrade, so
    /// brew's quit skips the second confirmation, which could sit unseen
    /// behind Terminal while brew waits. Expires in case the upgrade fails
    /// before it quits Plume, so a later ⌘Q still asks.
    @MainActor private static var quitConfirmedAt: Date?
    private static let quitConfirmationLifetime: TimeInterval = 5 * 60

    @MainActor
    static var isQuitConfirmed: Bool {
        guard let quitConfirmedAt else { return false }
        return Date().timeIntervalSince(quitConfirmedAt) < quitConfirmationLifetime
    }

    /// The upgrade command: update brew's taps, upgrade, then reopen Plume,
    /// since brew quits it and nothing else relaunches it. The explicit
    /// `brew update` matters because brew skips its own auto-update when one
    /// ran recently, which can leave the tap behind the appcast.
    static func command(brewPath: String, bundleID: String) -> String {
        let brew = TerminalCommandScript.shellQuoted(brewPath)
        return "\(brew) update && \(brew) upgrade --cask ryanmoelter/tap/plume && open -b \(TerminalCommandScript.shellQuoted(bundleID))"
    }

    /// Falls back to a bare `brew`, found on the login shell's PATH, when the
    /// install source was overridden on a machine with no detected Caskroom.
    static func brewPath(homebrewPrefix: URL?) -> String {
        homebrewPrefix?.appendingPathComponent("bin/brew").path ?? "brew"
    }

    @MainActor
    static func runInTerminal(homebrewPrefix: URL?) {
        let interrupted = AppDelegate.interruptedTabCount(statuses: StatusEngine.shared.effectiveTabStatuses)
        if interrupted > 0, AppSettings.shared.confirmQuitWhileWorking {
            guard confirmStoppingAgents(count: interrupted) else { return }
            quitConfirmedAt = Date()
        }
        let upgrade = command(
            brewPath: brewPath(homebrewPrefix: homebrewPrefix),
            bundleID: Bundle.main.bundleIdentifier ?? "com.ryanmoelter.Plume"
        )
        TerminalCommandScript.open(prefix: "plume-upgrade", command: upgrade, onFailure: presentFailure)
    }

    @MainActor
    private static func confirmStoppingAgents(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop Working Agents to Upgrade?"
        alert.informativeText = (count == 1 ? "An agent is" : "\(count) agents are") +
            " still working or waiting on you. Homebrew quits Plume to upgrade it, " +
            "which ends them without saving any in-progress response."
        alert.addButton(withTitle: "Upgrade")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func presentFailure(_ detail: String) {
        quitConfirmedAt = nil
        Log.app.error("Homebrew upgrade failed to open Terminal: \(detail, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Couldn't open Terminal"
        alert.informativeText = "\(detail)\n\nRun \(UpdateController.homebrewUpgradeCommand) in your terminal instead."
        alert.runModal()
    }
}
