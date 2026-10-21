import Foundation

@MainActor
extension WorkTask {
    /// One entry per distinct directory the task's agent tabs are open in.
    var agentDirectories: [String] {
        TaskRowDetails.distinctDirectories(
            agentTabDirectories: orderedLiveTabs
                .filter { $0.kind == .agent }
                .map { TabDirectoryStore.shared.directory(for: $0) },
            taskDirectory: workingDirectoryPath
        )
    }

    func displayedBranch(in directory: String) -> String? {
        GitState.displayedBranch(
            state: GitStateStore.shared.state(for: directory),
            taskBranchName: branchName
        )
    }

    /// The branches whose names can carry a working Linear issue: what each
    /// agent directory has checked out, plus the branch the task was made on.
    var linearBranches: [String] {
        var branches = agentDirectories.compactMap(displayedBranch(in:))
        if let branchName, !branches.contains(branchName) { branches.append(branchName) }
        return branches
    }
}
