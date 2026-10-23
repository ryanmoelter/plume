import Foundation

/// Changes a tab's `--add-dir` list, and restarts its running headless
/// session so the change takes effect.
///
/// The CLI can neither add nor remove a folder mid-session, and a resume
/// restores none, so the restart passes the whole list again. A running
/// turn is never cut short for it: the restart waits for the turn to end.
@MainActor
enum AdditionalDirectoryStore {
    enum AddError: Error, Equatable {
        case notAFolder(String)
    }

    /// Adds every folder in `paths`, skipping ones the tab already reaches.
    /// A relative path is taken against the tab's working directory.
    static func add(_ paths: [String], to tab: TaskTab) throws(AddError) {
        let workingDirectory = TabDirectoryStore.shared.directory(for: tab)
        var additions: [String] = []
        for path in paths {
            guard let normalized = AdditionalDirectories.normalized(path, relativeTo: workingDirectory),
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

    private static func update(_ tab: TaskTab, to paths: [String]) {
        let list = AdditionalDirectories.list(paths, excluding: TabDirectoryStore.shared.directory(for: tab))
        guard list != tab.additionalDirectories else { return }
        tab.additionalDirectories = list
        applyToRunningSession(of: tab)
    }

    private static func applyToRunningSession(of tab: TaskTab) {
        guard tab.provider == .claudeCode, tab.transport == .headless,
              let session = AgentSessionManager.shared.existingSession(for: tab.id) as? HeadlessSession,
              !session.hasExited
        else { return }
        let launchKeys = session.launchAdditionalDirectories.map(AdditionalDirectories.comparisonKey)
        guard launchKeys != tab.additionalDirectories.map(AdditionalDirectories.comparisonKey) else {
            session.cancelPendingRestart()
            return
        }
        let restart = { [weak tab] in
            guard let tab, let task = tab.task else { return }
            AgentLauncher.relaunchHeadless(task: task, tab: tab)
        }
        if session.isBusy {
            session.restartWhenIdle(restart)
        } else {
            restart()
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
