import Foundation

@MainActor
extension WorkTask {
    /// One entry per distinct directory the task's agent tabs are open in.
    var agentDirectories: [String] {
        TaskRowDetails.distinctDirectories(
            agentTabDirectories: orderedLiveTabs
                .filter { $0.kind == .agent }
                .map { TabDirectoryStore.shared.directory(for: $0) },
            fallbackDirectory: storedTabDirectory
        )
    }

    /// The first folder any tab saved, for a task whose agent tabs have none.
    var storedTabDirectory: String? {
        orderedLiveTabs.lazy.compactMap(\.workingDirectoryPath).first { !$0.isEmpty }
    }

    func displayedBranch(in directory: String) -> String? {
        GitState.displayedBranch(
            state: GitStateStore.shared.state(for: directory),
            storedBranchName: storedBranchName(in: directory)
        )
    }

    /// The first branch saved on a tab in `directory`.
    func storedBranchName(in directory: String) -> String? {
        orderedLiveTabs.lazy
            .filter { TabDirectoryStore.shared.directory(for: $0) == directory }
            .compactMap(\.branchName)
            .first
    }

    /// The branches whose names can carry a working Linear issue: what each
    /// agent directory has checked out, plus the branch each tab was made on.
    var linearBranches: [String] {
        var branches = agentDirectories.compactMap(displayedBranch(in:))
        for branch in orderedLiveTabs.compactMap(\.branchName) where !branches.contains(branch) {
            branches.append(branch)
        }
        return branches
    }
}
