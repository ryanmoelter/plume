import Foundation
import Testing
@testable import Plume

/// `stack undo` puts back the branch tips and state a ref-moving command
/// found, and a second undo redoes it.
struct StackUndoTests {
    let repo: StackScratchRepo
    let state: StackBranches

    /// `parent` → `child`, with `parent` grown past `child`'s base so a
    /// restack moves `child`.
    init() throws {
        repo = try StackScratchRepo()
        try repo.commit("trunk-one")
        let trunk = try repo.rev("HEAD")
        try repo.pushTrunk()
        try repo.git("switch", "-qc", "parent")
        try repo.commit("parent-one")
        let parentOne = try repo.rev("HEAD")
        try repo.git("switch", "-qc", "child")
        try repo.commit("child-one")
        try repo.git("switch", "-q", "parent")
        try repo.commit("parent-two")
        try repo.git("switch", "-q", "child")
        state = ["parent": entry("main", trunk), "child": entry("parent", parentOne)]
        try repo.writeState(state)
    }

    var store: StackUndoStore { StackUndoStore(directory: "\(repo.stateDirectory)/undo") }

    func current() throws -> String {
        try repo.git("symbolic-ref", "--short", "HEAD")
    }

    @Test func undoRestoresARestackAndASecondUndoRedoesIt() throws {
        let before = try repo.rev("child")
        try Stack.restack(repo.context(), [])
        let after = try repo.rev("child")
        #expect(after != before)
        let restacked = try repo.loadState()

        let console = BufferConsole()
        try Stack.undo(repo.context(console: console), [])
        #expect(try repo.rev("child") == before)
        #expect(try repo.loadState() == state)
        #expect(console.stdout.contains("child: moved \(after.prefix(10)) → \(before.prefix(10))"))
        #expect(store.list().map(\.command) == ["undo"])

        try Stack.undo(repo.context(), [])
        #expect(try repo.rev("child") == after)
        #expect(try repo.loadState() == restacked)
    }

    @Test func aNoOpRestackLeavesNoSnapshot() throws {
        try Stack.restack(repo.context(), [])
        #expect(store.list().count == 1)
        try Stack.restack(repo.context(), [])
        #expect(store.list().map(\.command) == ["restack"])
    }

    @Test func undoAfterSplitDeletesTheNewBranches() throws {
        let one = try repo.commit("child-two")
        try repo.commit("child-three")
        let tip = try repo.rev("child")
        try Stack.split(repo.context(), ["lower:\(one)"])
        #expect(try repo.localBranches().contains("lower"))

        let console = BufferConsole()
        try Stack.undo(repo.context(console: console), [])
        #expect(try !repo.localBranches().contains("lower"))
        #expect(try repo.loadState() == state)
        #expect(try repo.rev("child") == tip)
        #expect(console.stdout.contains("lower: deleted (was \(one.prefix(10));"))
    }

    @Test func undoAfterCreateInsertSwitchesBack() throws {
        try repo.git("switch", "-q", "parent")
        try Stack.create(repo.context(), ["middle", "--insert"])
        #expect(try current() == "middle")
        try Stack.undo(repo.context(), [])
        #expect(try current() == "parent")
        #expect(try !repo.localBranches().contains("middle"))
        #expect(try repo.loadState() == state)
    }

    @Test func undoRecreatesADeletedBranch() throws {
        let tip = try repo.rev("child")
        _ = try repo.context().recordUndo("sync", state)
        try repo.git("switch", "-q", "parent")
        try repo.git("branch", "-D", "child")
        try repo.writeState(["parent": state["parent"]!])

        try Stack.undo(repo.context(), [])
        #expect(try repo.rev("child") == tip)
        #expect(try current() == "child")
        #expect(try repo.loadState() == state)
    }

    @Test func undoRefusesADirtyTree() throws {
        try Stack.restack(repo.context(), [])
        try repo.write("child-one", "edited")
        #expect(stackFailure { try Stack.undo(repo.context(), []) }?.message == "working tree not clean — commit or stash first")
    }

    @Test func undoWithNothingRecordedSaysSo() throws {
        #expect(stackFailure { try Stack.undo(repo.context(), []) }?.message?.hasPrefix("nothing to undo") == true)
    }

    @Test func listWithoutATerminalPrintsAndANumberPicksAnOlderSnapshot() throws {
        let original = try repo.rev("child")
        try Stack.restack(repo.context(), [])
        try repo.git("switch", "-q", "parent")
        try repo.commit("parent-three")
        try repo.git("switch", "-q", "child")
        try Stack.restack(repo.context(), [])

        let console = BufferConsole()
        try Stack.undo(repo.context(console: console), ["--list"])
        #expect(console.stdout.hasPrefix("snapshots, newest first (restore one with `stack undo <n>`):\n"))
        #expect(console.stdout.contains(" 2) "))

        try Stack.undo(repo.context(), ["2", "--dry-run"])
        #expect(try repo.rev("child") != original)
        try Stack.undo(repo.context(), ["2"])
        #expect(try repo.rev("child") == original)
        #expect(try repo.loadState() == state)
    }

    @Test func aBranchCheckedOutInAnotherWorktreeIsResetThere() throws {
        let before = try repo.rev("child")
        try Stack.restack(repo.context(), [])
        try repo.git("switch", "-q", "parent")
        let other = "\(repo.directory)/other"
        try repo.git("worktree", "add", "-q", other, "child")

        try repo.write("child-one", "edited", in: other)
        #expect(stackFailure { try Stack.undo(repo.context(), []) }?.message?.contains("with uncommitted changes") == true)

        try repo.git("checkout", "--", "child-one", in: other)
        try Stack.undo(repo.context(), [])
        #expect(try repo.rev("child") == before)
        #expect(try repo.git("rev-parse", "HEAD", in: other) == before)
        #expect(try repo.git("status", "--porcelain", in: other).isEmpty)
    }

    @Test func snapshotsRoundTripAndKeepOnlyTheNewest() throws {
        let snapshot = StackUndoSnapshot(
            id: "",
            command: "restack --all",
            created: Date(timeIntervalSince1970: 1_800_000_000.5),
            worktree: "/repo",
            current: "child",
            tips: ["child": "abc", "main": "def"],
            state: ["child": StackEntry(parent: "main", base: "def", extra: [StackJSONMember("note", .string("x"))])]
        )
        let id = try store.save(snapshot)
        var expected = snapshot
        expected.id = id
        #expect(store.list() == [expected])
        for _ in 0 ..< StackUndoStore.retained { try store.save(snapshot) }
        #expect(store.list().count == StackUndoStore.retained)
        #expect(!store.list().contains { $0.id == id })
    }

    @Test func thePlanCoversOnlyStackBranches() {
        let snapshot = StackUndoSnapshot(
            id: "x", command: "c", created: Date(), worktree: "/", current: nil,
            tips: ["a": "1", "b": "2", "gone": "3", "other": "4"],
            state: ["a": entry("main", "0"), "b": entry("a", "1"), "gone": entry("b", "2")]
        )
        let changes = StackUndoChange.plan(
            snapshot,
            state: ["a": entry("main", "0"), "b": entry("a", "1"), "new": entry("b", "2")],
            tips: ["a": "1", "b": "9", "new": "8", "other": "7"]
        )
        #expect(changes == [
            .move(branch: "b", from: "9", to: "2"),
            .create(branch: "gone", at: "3"),
            .delete(branch: "new", at: "8"),
        ])
    }
}
