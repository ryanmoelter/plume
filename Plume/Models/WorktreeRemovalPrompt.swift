import Foundation

/// The action a worktree-removal dialog is confirming. Delete and archive
/// share every other part of the flow — only the verb in the copy differs.
enum WorktreeRemovalVerb {
    case delete
    case archive

    var title: String {
        switch self {
        case .delete: "Delete"
        case .archive: "Archive"
        }
    }

    /// The confirmation dialog's title, shared by every removal flow that
    /// confirms against a task by name.
    func dialogTitle(for taskTitle: String) -> String {
        "\(title) “\(taskTitle)”?"
    }
}

/// A worktree Plume made for one of a task's tabs, as git lists it.
nonisolated struct WorktreeRemovalTarget: Hashable, Sendable {
    let repository: String
    let path: String
    let branch: String?
}

/// Whether removing a task's worktrees needs confirmation first, shared by the
/// delete and archive flows so neither can drift from the other.
///
/// Kept out of the views so it is testable without SwiftData or a dialog.
enum WorktreeRemovalPrompt {
    /// A worktree removal awaiting confirmation. `dirtySummaries` is filled in
    /// only once the async uncommitted-changes checks resolve, so the dialog
    /// never presents until its copy is final — its text must not change
    /// while the user is looking at it.
    struct PendingRemoval: Identifiable {
        let task: WorkTask
        let verb: WorktreeRemovalVerb
        let worktrees: [WorktreeRemovalTarget]
        /// Keyed by worktree path; a clean worktree has no entry.
        let dirtySummaries: [String: String]

        var id: UUID { task.id }

        private var isSingle: Bool { worktrees.count == 1 }

        var dialogTitle: String {
            verb.dialogTitle(for: task.title)
        }

        var primaryButtonTitle: String {
            "\(verb.title) and Remove \(isSingle ? "Worktree" : "Worktrees")"
        }

        var withBranchButtonTitle: String {
            isSingle
                ? "\(verb.title), Remove Worktree and Branch"
                : "\(verb.title), Remove Worktrees and Branches"
        }

        var taskOnlyButtonTitle: String {
            switch verb {
            case .delete: "Delete Task Only"
            case .archive: "Archive Task Only"
            }
        }

        var message: String {
            if isSingle, let worktree = worktrees.first {
                let base = "This task uses the worktree at \(worktree.path) on branch \(worktree.branch ?? "")."
                guard let dirtySummary = dirtySummaries[worktree.path] else { return base }
                return "\(base)\n\n\(dirtySummary)\n\nRemoving the worktree discards this work, and it cannot be recovered."
            }
            let list = worktrees.map { "• \($0.path) on branch \($0.branch ?? "")" }.joined(separator: "\n")
            let base = "This task uses \(worktrees.count) worktrees:\n\(list)"
            let dirty = worktrees.compactMap { worktree in
                dirtySummaries[worktree.path].map { "In \(worktree.path), \($0)" }
            }
            guard !dirty.isEmpty else { return base }
            let warnings = dirty.joined(separator: "\n\n")
            return "\(base)\n\n\(warnings)\n\nRemoving the worktrees discards this work, and it cannot be recovered."
        }
    }

    /// What one tab asks to remove, before git says which worktree that is.
    nonisolated struct Claim: Hashable, Sendable {
        let repository: String
        let branch: String?
        let directory: String?
    }

    /// True when a tab of `task` uses a Plume-created worktree, so removing it
    /// needs a decision rather than happening silently underneath delete or
    /// archive.
    static func needsConfirmation(for task: WorkTask) -> Bool {
        task.tabs.contains { $0.workspaceKind == .worktree }
    }

    static func claims(for task: WorkTask, directories: TabDirectoryStore = .shared) -> [Claim] {
        task.orderedTabs.compactMap { tab in
            guard tab.workspaceKind == .worktree, let repository = tab.repoPath else { return nil }
            return Claim(repository: repository, branch: tab.branchName, directory: directories.directory(for: tab))
        }
    }

    /// Each claim's worktree, once per path. A tab's folder follows the tab
    /// wherever it moves, so a claim matches by the branch its worktree was
    /// made on, and by folder only when it has no branch: `git worktree
    /// remove --force` on a folder the tab merely wandered into would delete
    /// someone else's work.
    nonisolated static func targets(
        for claims: [Claim],
        worktrees: (String) -> [GitWorktree]
    ) -> [WorktreeRemovalTarget] {
        var targets: [WorktreeRemovalTarget] = []
        for claim in claims {
            let linked = worktrees(claim.repository).filter { !$0.isMain }
            let match: GitWorktree? = if let branch = claim.branch {
                linked.first { $0.branch == branch }
            } else if let directory = claim.directory {
                linked.first { directory == $0.path || directory.hasPrefix($0.path + "/") }
            } else {
                nil
            }
            guard let match, !targets.contains(where: { $0.path == match.path }) else { continue }
            targets.append(WorktreeRemovalTarget(repository: claim.repository, path: match.path, branch: match.branch))
        }
        return targets
    }

    static func targets(for task: WorkTask) async -> [WorktreeRemovalTarget] {
        let claims = claims(for: task)
        var listings: [String: [GitWorktree]] = [:]
        for repository in Set(claims.map(\.repository)) {
            listings[repository] = await GitService.shared.worktrees(in: repository)
        }
        return targets(for: claims) { listings[$0] ?? [] }
    }

    /// Porcelain status as a sentence and a short list. The codes mean nothing
    /// to a reader deciding whether to lose the work, so only the paths show.
    static func describe(_ changes: [String]) -> String {
        let paths = changes.map { $0.dropFirst(3) }.map(String.init)
        let count = paths.count
        let noun = count == 1 ? "file has" : "files have"
        let shown = paths.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let more = count > 5 ? "\n• and \(count - 5) more" : ""
        return "\(count) \(noun) uncommitted changes:\n\(shown)\(more)"
    }
}
