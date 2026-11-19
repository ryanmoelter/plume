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

/// An owned worktree git still lists, ready to remove.
nonisolated struct WorktreeRemovalTarget: Hashable, Sendable {
    let repository: String
    let path: String
    /// The branch Plume created, or nil once it no longer exists, so removing
    /// the branch never deletes one made later under the same name.
    let branch: String?
}

/// What archive or delete would do with a task's `ownedWorktrees`, shared by
/// both flows so neither can drift from the other.
///
/// Kept out of the views so it is testable without SwiftData or a dialog.
enum WorktreeRemovalPrompt {
    /// Every owned worktree, sorted by what can happen to it.
    nonisolated struct Plan: Equatable, Sendable {
        var removable: [WorktreeRemovalTarget] = []
        /// Kept, because a tab of another task has its folder there.
        var inUse: [InUse] = []
        /// Recorded, but git no longer lists it as a worktree.
        var gone: [String] = []
    }

    nonisolated struct InUse: Equatable, Sendable {
        let worktree: OwnedWorktree
        let taskID: UUID
        let taskTitle: String

        var path: String { worktree.path }
    }

    /// A live tab of another task, saved at `folder`.
    nonisolated struct User: Equatable, Sendable {
        let folder: String
        let taskID: UUID
        let taskTitle: String
    }

    /// A worktree removal awaiting confirmation. `dirtySummaries` is filled in
    /// only once the async uncommitted-changes checks resolve, so the dialog
    /// never presents until its copy is final — its text must not change
    /// while the user is looking at it.
    struct PendingRemoval: Identifiable {
        let task: WorkTask
        let verb: WorktreeRemovalVerb
        let plan: Plan
        /// Keyed by worktree path; a clean worktree has no entry.
        let dirtySummaries: [String: String]

        var id: UUID { task.id }

        var worktrees: [WorktreeRemovalTarget] { plan.removable }

        private var isSingle: Bool { worktrees.count == 1 }

        var offersRemoval: Bool { !worktrees.isEmpty }

        var offersBranchRemoval: Bool { worktrees.contains { $0.branch != nil } }

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
            guard offersRemoval else { return verb.title }
            return switch verb {
            case .delete: "Delete Task Only"
            case .archive: "Archive Task Only"
            }
        }

        var message: String {
            var parts: [String] = []
            if isSingle, let worktree = worktrees.first {
                parts.append("This task uses the worktree at \(worktree.path)\(onBranch(worktree)).")
            } else if !worktrees.isEmpty {
                let list = worktrees.map { "• \($0.path)\(onBranch($0))" }.joined(separator: "\n")
                parts.append("This task uses \(worktrees.count) worktrees:\n\(list)")
            }
            if !plan.inUse.isEmpty {
                let list = plan.inUse.map { "• \($0.path), used by “\($0.taskTitle)”" }.joined(separator: "\n")
                parts.append("Kept, because another task is using it:\n\(list)")
            }
            if !plan.gone.isEmpty {
                let list = plan.gone.map { "• \($0)" }.joined(separator: "\n")
                parts.append("No longer a worktree:\n\(list)")
            }
            let dirty = worktrees.compactMap { worktree in
                dirtySummaries[worktree.path].map { isSingle ? $0 : "In \(worktree.path), \($0)" }
            }
            if !dirty.isEmpty {
                parts.append(contentsOf: dirty)
                parts.append("Removing the \(isSingle ? "worktree" : "worktrees") discards this work, and it cannot be recovered.")
            }
            return parts.joined(separator: "\n\n")
        }

        private func onBranch(_ worktree: WorktreeRemovalTarget) -> String {
            worktree.branch.map { " on branch \($0)" } ?? ""
        }
    }

    static func needsConfirmation(for task: WorkTask) -> Bool {
        !task.ownedWorktrees.isEmpty
    }

    /// Every saved folder of another task's live tabs, in task order. All of
    /// them, since which worktree each is in is known only once git answers.
    /// Archived tasks don't count: nothing runs in them.
    static func users(of task: WorkTask, among tasks: [WorkTask], titles: TitleStore = .shared) -> [User] {
        tasks.filter { $0.id != task.id && !$0.isArchived }.flatMap { other in
            other.liveTabs.compactMap(\.workingDirectoryPath).map {
                User(folder: $0, taskID: other.id, taskTitle: titles.displayTitle(for: other))
            }
        }
    }

    /// Deleting a task leaves a worktree another task still uses to that
    /// task, so deleting that one later can still remove it.
    static func handOff(_ inUse: [InUse], among tasks: [WorkTask]) {
        for kept in inUse {
            tasks.first { $0.id == kept.taskID }?.recordOwnedWorktree(kept.worktree)
        }
    }

    /// A record matches the listed worktree it is at or inside, since an
    /// older build could save a subfolder, and the worktree's root is what
    /// gets removed. An empty listing means git failed, so the record is
    /// offered anyway with the branch it names: losing track of the worktree
    /// is worse than a removal git then refuses.
    nonisolated static func plan(
        for worktrees: [OwnedWorktree],
        users: [User],
        listing: (String) -> [GitWorktree],
        branchExists: (String, String) -> Bool
    ) -> Plan {
        var plan = Plan()
        var seen: Set<String> = []
        for record in worktrees {
            let listed = listing(record.repoPath)
            var root = record.path
            if !listed.isEmpty {
                let match = listed
                    .map { (worktree: $0, root: OwnedWorktree.standardized($0.path)) }
                    .filter { record.path == $0.root || record.path.hasPrefix($0.root + "/") }
                    .max { $0.root.count < $1.root.count }
                if let match, match.worktree.isMain, match.root == record.path { continue }
                // Inside the main checkout is where a deleted worktree often was.
                guard let match, !match.worktree.isMain else {
                    plan.gone.append(record.path)
                    continue
                }
                root = match.root
            }
            guard seen.insert(root).inserted else { continue }
            let worktree = OwnedWorktree(path: root, repoPath: record.repoPath, branch: record.branch)
            if let user = users.first(where: { worktree.contains($0.folder) }) {
                plan.inUse.append(InUse(worktree: worktree, taskID: user.taskID, taskTitle: user.taskTitle))
                continue
            }
            let branch = listed.isEmpty
                ? record.branch
                : record.branch.flatMap { branchExists(record.repoPath, $0) ? $0 : nil }
            plan.removable.append(WorktreeRemovalTarget(repository: record.repoPath, path: root, branch: branch))
        }
        return plan
    }

    /// The git calls `resolve` makes, each of which blocks.
    nonisolated struct Git: Sendable {
        var worktrees: @Sendable (_ repository: String) -> [GitWorktree]
        var branchExists: @Sendable (_ repository: String, _ branch: String) -> Bool
        var uncommittedChanges: @Sendable (_ path: String) -> [String]

        static let live = Git(
            worktrees: { GitRunner.worktrees(in: $0) },
            branchExists: { repository, branch in
                (try? GitRunner.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repository)) != nil
            },
            uncommittedChanges: { WorkspaceProvisioner.uncommittedChanges(in: $0) }
        )
    }

    /// The plan, with each removable worktree's uncommitted changes
    /// summarized. Each `git` runs at once rather than queuing on
    /// `GitService`, since the dialog waits on all of them, and off the main
    /// actor, since each blocks.
    @concurrent
    nonisolated static func resolve(
        _ worktrees: [OwnedWorktree],
        users: [User],
        git: Git = .live
    ) async -> (plan: Plan, dirtySummaries: [String: String]) {
        let repositories = Set(worktrees.map(\.repoPath))
        let listings = await withTaskGroup(of: (String, [GitWorktree]).self) { group in
            for repository in repositories {
                group.addTask { (repository, git.worktrees(repository)) }
            }
            return await group.reduce(into: [String: [GitWorktree]]()) { $0[$1.0] = $1.1 }
        }
        let plan = plan(for: worktrees, users: users, listing: { listings[$0] ?? [] }, branchExists: git.branchExists)
        let dirtySummaries = await withTaskGroup(of: (String, [String]).self) { group in
            for worktree in plan.removable {
                group.addTask { (worktree.path, git.uncommittedChanges(worktree.path)) }
            }
            return await group.reduce(into: [String: String]()) { summaries, result in
                if !result.1.isEmpty { summaries[result.0] = describe(result.1) }
            }
        }
        return (plan, dirtySummaries)
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
