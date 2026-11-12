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

    /// The workspaces `task` answers for: its tabs', or the one it holds
    /// once its last tab has gone.
    private static func workspaces(of task: WorkTask) -> [TabWorkspace] {
        task.tabs.isEmpty ? [task.heldWorkspace] : task.orderedTabs.map(\.workspace)
    }

    /// True when `task` uses a Plume-created worktree, so removing it needs a
    /// decision rather than happening silently underneath delete or archive.
    static func needsConfirmation(for task: WorkTask) -> Bool {
        workspaces(of: task).contains { $0.kind == .worktree }
    }

    static func claims(for task: WorkTask) -> [Claim] {
        workspaces(of: task).compactMap { workspace in
            guard workspace.kind == .worktree, let repository = workspace.repoPath else { return nil }
            return Claim(repository: repository, branch: workspace.branchName, directory: workspace.directory)
        }
    }

    /// Each claim's worktree, once per path, and never the main checkout.
    ///
    /// A tab's saved folder follows it, so a claim matches first by the branch
    /// its worktree was made on: `git worktree remove --force` on a folder the
    /// tab merely wandered into would delete someone else's work. The folder
    /// answers only when no worktree is on that branch, as after a rename or
    /// on a detached HEAD. A repository git lists no worktrees for, as when
    /// the listing failed, falls back to the folder itself.
    nonisolated static func targets(
        for claims: [Claim],
        worktrees: (String) -> [GitWorktree]
    ) -> [WorktreeRemovalTarget] {
        var targets: [WorktreeRemovalTarget] = []
        for claim in claims {
            let listing = worktrees(claim.repository)
            let match: WorktreeRemovalTarget?
            if listing.isEmpty {
                match = claim.directory.map { WorktreeRemovalTarget(repository: claim.repository, path: $0, branch: claim.branch) }
            } else {
                let linked = listing.filter { !$0.isMain }
                let byBranch = claim.branch.flatMap { branch in linked.first { $0.branch == branch } }
                let byFolder = claim.directory.flatMap { directory in
                    linked.first { directory == $0.path || directory.hasPrefix($0.path + "/") }
                }
                match = (byBranch ?? byFolder).map {
                    WorktreeRemovalTarget(repository: claim.repository, path: $0.path, branch: $0.branch)
                }
            }
            guard let match,
                  match.path != claim.repository,
                  !listing.contains(where: { $0.isMain && $0.path == match.path }),
                  !targets.contains(where: { $0.path == match.path })
            else { continue }
            targets.append(match)
        }
        return targets
    }

    /// The targets, each with its uncommitted changes summarized when it has
    /// any. Each `git` runs at once rather than queuing on `GitService`, since
    /// the dialog waits on all of them.
    nonisolated static func resolve(
        _ claims: [Claim]
    ) async -> (worktrees: [WorktreeRemovalTarget], dirtySummaries: [String: String]) {
        let repositories = Set(claims.map(\.repository))
        let listings = await withTaskGroup(of: (String, [GitWorktree]).self) { group in
            for repository in repositories {
                group.addTask { (repository, GitRunner.worktrees(in: repository)) }
            }
            return await group.reduce(into: [String: [GitWorktree]]()) { $0[$1.0] = $1.1 }
        }
        let worktrees = targets(for: claims) { listings[$0] ?? [] }
        let dirtySummaries = await withTaskGroup(of: (String, [String]).self) { group in
            for worktree in worktrees {
                group.addTask { (worktree.path, WorkspaceProvisioner.uncommittedChanges(in: worktree.path)) }
            }
            return await group.reduce(into: [String: String]()) { summaries, result in
                if !result.1.isEmpty { summaries[result.0] = describe(result.1) }
            }
        }
        return (worktrees, dirtySummaries)
    }

    /// Porcelain status as a sentence and a short list. The codes mean nothing
    /// to a reader deciding whether to lose the work, so only the paths show.
    nonisolated static func describe(_ changes: [String]) -> String {
        let paths = changes.map { $0.dropFirst(3) }.map(String.init)
        let count = paths.count
        let noun = count == 1 ? "file has" : "files have"
        let shown = paths.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let more = count > 5 ? "\n• and \(count - 5) more" : ""
        return "\(count) \(noun) uncommitted changes:\n\(shown)\(more)"
    }
}
