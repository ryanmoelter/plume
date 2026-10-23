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
/// directory. Only a launch drops the folder it starts in, so the store, the
/// launch and the restart check all measure against the session's own
/// `launchDirectory`.
@MainActor
enum AdditionalDirectoryStore {
    enum AddError: Error, Equatable {
        case notAFolder(String)
    }

    /// Adds every folder in `paths`, skipping ones the tab already lists.
    /// A relative path is taken against the tab's working directory.
    static func add(_ paths: [String], to tab: TaskTab) throws(AddError) {
        let base = runningSession(of: tab)?.launchDirectory ?? TabDirectoryStore.shared.directory(for: tab)
        var additions: [String] = []
        for path in paths {
            guard let normalized = AdditionalDirectories.normalized(path, relativeTo: base),
                  isFolder(normalized)
            else { throw .notAFolder(path) }
            additions.append(normalized)
        }
        update(tab, to: tab.additionalDirectories + additions)
    }

    static func remove(_ path: String, from tab: TaskTab) {
        let key = AdditionalDirectories.comparisonKey(path)
        update(tab, to: tab.additionalDirectories.filter { AdditionalDirectories.comparisonKey($0) != key })
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
        AgentLauncher.relaunchHeadless(task: task, tab: tab)
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
        let launchKeys = session.launchAdditionalDirectories.map(AdditionalDirectories.comparisonKey)
        let wanted = AdditionalDirectories.list(tab.additionalDirectories, excluding: session.launchDirectory)
        guard launchKeys != wanted.map(AdditionalDirectories.comparisonKey) else {
            session.cancelPendingRestart()
            return
        }
        let restart = { [weak tab] in
            guard let tab, let task = tab.task else { return }
            AgentLauncher.relaunchHeadless(task: task, tab: tab)
        }
        session.restartWhenIdle(restart)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
