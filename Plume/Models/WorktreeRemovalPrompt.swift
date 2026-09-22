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
}

/// Whether removing a task's worktree needs confirmation first, shared by the
/// delete and archive flows so neither can drift from the other.
///
/// Kept out of the views so it is testable without SwiftData or a dialog.
enum WorktreeRemovalPrompt {
    /// A worktree removal awaiting confirmation. `dirtySummary` is filled in
    /// only once the async uncommitted-changes check resolves, so the dialog
    /// never presents until its copy is final — its text must not change
    /// while the user is looking at it.
    struct PendingRemoval: Identifiable {
        let task: WorkTask
        let verb: WorktreeRemovalVerb
        let dirtySummary: String?

        var id: UUID { task.id }

        var dialogTitle: String {
            "\(verb.title) “\(task.title)”?"
        }

        var primaryButtonTitle: String {
            "\(verb.title) and Remove Worktree"
        }

        var withBranchButtonTitle: String {
            "\(verb.title), Remove Worktree and Branch"
        }

        var taskOnlyButtonTitle: String {
            switch verb {
            case .delete: "Delete Task Only"
            case .archive: "Archive Task Only"
            }
        }

        var message: String {
            let base = "This task uses the worktree at \(task.workingDirectoryPath ?? "") on branch \(task.branchName ?? "")."
            guard let dirtySummary else { return base }
            return "\(base)\n\n\(dirtySummary)\n\nRemoving the worktree discards this work, and it cannot be recovered."
        }
    }

    /// True when `task` owns a Plume-created worktree, so removing it needs a
    /// decision rather than happening silently underneath delete or archive.
    static func needsConfirmation(for task: WorkTask) -> Bool {
        task.workspaceKind == .worktree
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
