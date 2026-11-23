import Testing
@testable import Plume

@MainActor
struct BranchDisplayTests {
    @Test func gitAnswerBeatsLastKnownAndStored() {
        let state = GitState(branch: "live", upstream: nil, ahead: 0, behind: 0, isDirty: false)
        #expect(GitState.displayedBranch(state: state, storedBranchName: "stored", lastKnownBranch: "old") == "live")
    }

    @Test func lastKnownBranchCoversAMissingFolder() {
        #expect(GitState.displayedBranch(state: nil, storedBranchName: "stored", lastKnownBranch: "old") == "old")
        #expect(GitState.displayedBranch(state: nil, storedBranchName: "stored") == "stored")
        #expect(GitState.displayedBranch(state: nil, storedBranchName: nil) == nil)
    }

    @Test func storeKeepsTheLastBranchAfterGitStopsAnswering() {
        let store = GitStateStore()
        defer { store.reset() }
        store.seedFixture(
            directory: "/gone", state: GitState(branch: "feature", upstream: nil, ahead: 0, behind: 0, isDirty: false)
        )
        store.watch("/gone")
        #expect(store.lastKnownBranch(for: "/gone") == "feature")
        store.forget(directory: "/gone")
        #expect(store.lastKnownBranch(for: "/gone") == nil)
    }

    @Test func chosenFolderKeepsTheBranchOnlyInsideTheRepository() {
        #expect(WorkspacePickerView.isInside("/r/app/sub", repository: "/r/app"))
        #expect(WorkspacePickerView.isInside("/r/app", repository: "/r/app"))
        #expect(!WorkspacePickerView.isInside("/r/app2", repository: "/r/app"))
        #expect(!WorkspacePickerView.isInside("/r/app", repository: nil))
    }
}
