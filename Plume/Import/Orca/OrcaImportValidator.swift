import Foundation

/// `ImportValidator` configured for Orca: a lost transcript leaves a plain
/// terminal, and a Codex pane stays an agent only when Plume's own Codex can
/// resume its thread.
///
/// One value serves a whole import sheet, so the rollout index is built once.
nonisolated struct OrcaImportValidator: Sendable {
    private let rollouts: CodexRolloutIndex

    init(rollouts: CodexRolloutIndex = CodexRolloutIndex(sessionsDirectory: CodexRollouts.sessionsDirectory)) {
        self.rollouts = rollouts
    }

    func validating(_ candidate: ImportCandidate) async -> ImportCandidate {
        let rollouts = rollouts
        return await ImportValidator.validating(
            candidate,
            configuration: .init(
                missingTranscript: .downgradeToTerminal,
                resolveCodexTab: { Self.resolvingCodexTab($0, rollouts: rollouts) },
                readsBranchFromGit: true
            )
        )
    }

    static func resolvingCodexTab(_ tab: ImportTabPlan, rollouts: CodexRolloutIndex) -> ImportTabPlan {
        let found = tab.agentSessionID.flatMap {
            CodexRollouts.rolloutPath(
                sessionID: $0,
                recorded: tab.sessionJSONLPath,
                cwd: tab.workingDirectoryPath,
                rollouts: rollouts
            )
        }
        return ImportValidator.resolvingCodexTab(tab, hasValidRollout: found != nil)
    }
}

/// Where Plume's Codex keeps the rollouts `thread/resume` can find.
///
/// Orca runs Codex with its own `CODEX_HOME`, and copies rollouts back into
/// the user's later, so a rollout Orca recorded may not be anywhere Plume's
/// app-server looks.
nonisolated enum CodexRollouts {
    static var sessionsDirectory: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions")
    }

    /// The rollout for `sessionID` under the index's directory, checked to hold
    /// that thread. `recorded` is tried first, and counts only if it is there.
    /// Orca records the `cwd` a pane was opened in, anywhere inside its worktree.
    static func rolloutPath(sessionID: String, recorded: String?, cwd: String?, rollouts: CodexRolloutIndex) -> String? {
        let root = rollouts.sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        if let recorded,
           URL(fileURLWithPath: recorded).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/"),
           CmuxCodexSessions.validRollout(path: recorded, sessionID: sessionID, cwd: cwd, cwdMatch: .insideDirectory) {
            return recorded
        }
        return rollouts.paths(forSessionID: sessionID).first {
            CmuxCodexSessions.validRollout(path: $0, sessionID: sessionID, cwd: cwd, cwdMatch: .insideDirectory)
        }
    }
}

/// Every rollout file under a sessions directory, listed on first use and then
/// kept, so a validation pass walks the directory once.
nonisolated final class CodexRolloutIndex: @unchecked Sendable {
    let sessionsDirectory: URL
    private let lock = NSLock()
    private var files: [URL]?

    init(sessionsDirectory: URL) {
        self.sessionsDirectory = sessionsDirectory
    }

    /// Codex names a rollout `rollout-<timestamp>-<thread id>.jsonl`.
    func paths(forSessionID sessionID: String) -> [String] {
        let suffix = "-\(sessionID).jsonl"
        return rolloutFiles().map(\.path).filter { ($0 as NSString).lastPathComponent.hasSuffix(suffix) }
    }

    private func rolloutFiles() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        if let files { return files }
        var found: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { found.append(url) }
            }
        }
        files = found
        return found
    }
}
