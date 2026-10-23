import Foundation

/// Changes a tab's `--add-dir` list, and restarts its running headless
/// session so the change takes effect.
///
/// The CLI can neither add nor remove a folder mid-session, and a resume
/// restores none, so the restart passes the whole list again. Nothing
/// running is cut short for it: the restart waits until the session is idle
/// (`HeadlessSession.restartBlockers`), unless the user forces it with
/// `restartNow`.
///
/// The stored list keeps every folder the user adds, even the working
/// directory. Only a launch drops the folder it starts in, so the launch and
/// the restart check both measure against the session's own
/// `launchDirectory`.
@MainActor
enum AdditionalDirectoryStore {
    /// Adds every folder in `paths` the tab does not already reach, and
    /// returns the paths that are not folders. A relative path is taken
    /// against the tab's working directory.
    @discardableResult
    static func add(_ paths: [String], to tab: TaskTab, history: UserDefaults = .standard) async -> [String] {
        let base = runningSession(of: tab)?.launchDirectory ?? TabDirectoryStore.shared.directory(for: tab)
        let existing = tab.additionalDirectories
        let found = await Task.detached {
            AdditionalDirectories.additions(paths, to: existing, relativeTo: base)
        }.value
        // The list may have changed while the file system was read.
        update(tab, to: tab.additionalDirectories + found.additions)
        RecentLinkedFolders.remember(found.additions, in: history)
        return found.rejected
    }

    static func remove(_ path: String, from tab: TaskTab) {
        let target = AdditionalDirectories.normalized(path)
        update(tab, to: tab.additionalDirectories.filter { AdditionalDirectories.normalized($0) != target })
    }

    /// Folders the running process reports reaching beyond its launch list.
    /// The session has already counted them as launched, so no restart follows.
    static func adopt(_ paths: [String], into tab: TaskTab, history: UserDefaults = .standard) {
        let list = AdditionalDirectories.list(tab.additionalDirectories + paths, excluding: nil)
        guard list != tab.additionalDirectories else { return }
        tab.additionalDirectories = list
        RecentLinkedFolders.remember(paths, in: history)
    }

    static func canRestartNow(_ session: HeadlessSession) -> Bool {
        let blockers = session.restartBlockers
        return session.isRestartPending && !blockers.isEmpty && blockers.allSatisfy(\.canBeCutShort)
    }

    /// Applies a waiting change at once, ending whatever background work
    /// held it. A side question still waiting is failed, since the new
    /// process will never answer it.
    static func restartNow(_ tab: TaskTab) {
        guard let session = runningSession(of: tab), canRestartNow(session), let task = tab.task else { return }
        session.abandonUnansweredSideQuestions()
        AgentLauncher.restartHeadless(task: task, tab: tab)
    }

    private static func update(_ tab: TaskTab, to paths: [String]) {
        let list = AdditionalDirectories.list(paths, excluding: nil)
        guard list != tab.additionalDirectories else { return }
        tab.additionalDirectories = list
        applyToRunningSession(of: tab)
    }

    private static func runningSession(of tab: TaskTab) -> HeadlessSession? {
        guard tab.provider == .claudeCode, tab.transport == .headless,
              let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession,
              !session.hasExited
        else { return nil }
        return session
    }

    private static func applyToRunningSession(of tab: TaskTab) {
        guard let session = runningSession(of: tab) else { return }
        guard AdditionalDirectories.needsRestart(
            launched: session.launchAdditionalDirectories,
            stored: tab.additionalDirectories,
            launchDirectory: session.launchDirectory
        ) else {
            session.cancelPendingRestart()
            return
        }
        session.restartWhenIdle { [weak tab] in
            guard let tab, let task = tab.task else { return false }
            return AgentLauncher.restartHeadless(task: task, tab: tab)
        }
    }
}
