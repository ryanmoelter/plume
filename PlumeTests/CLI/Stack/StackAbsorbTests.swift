import Foundation
import Testing
@testable import Plume

/// `stack absorb` folds each staged hunk into the stack commit that last
/// touched its lines, rebuilding the branches above, and leaves the rest
/// staged.
struct StackAbsorbTests {
    let repo: StackScratchRepo
    let console = BufferConsole()

    static let parentFile = (1 ... 12).map { "p\($0)" }
    static let childFile = (1 ... 12).map { "c\($0)" }

    /// `parent` adds `p.txt`, `child` adds `c.txt` and then a second commit
    /// on top; `main` holds `t.txt`.
    init() throws {
        repo = try StackScratchRepo()
        try commit("t.txt", (1 ... 6).map { "t\($0)" }, "trunk file")
        try repo.pushTrunk()
        try repo.git("switch", "-qc", "parent")
        try commit("p.txt", Self.parentFile, "add p")
        try repo.git("switch", "-qc", "child")
        try commit("c.txt", Self.childFile, "add c")
        try commit("c2.txt", ["x"], "add c2")
        try repo.writeState([
            "parent": entry("main", try repo.rev("main")),
            "child": entry("parent", try repo.rev("parent")),
        ])
    }

    func commit(_ name: String, _ lines: [String], _ message: String) throws {
        try write(name, lines)
        try repo.git("add", name)
        try repo.git("commit", "-q", "-m", message)
    }

    func write(_ name: String, _ lines: [String]) throws {
        try repo.write(name, lines.joined(separator: "\n") + "\n")
    }

    func edit(_ name: String, _ lines: [String], replacing index: Int, with text: String, stage: Bool = true) throws {
        var lines = lines
        lines[index] = text
        try write(name, lines)
        if stage { try repo.git("add", name) }
    }

    func show(_ rev: String, _ file: String) throws -> String {
        try repo.git("show", "\(rev):\(file)")
    }

    @Test func eachHunkLandsInTheCommitThatTouchedIt() throws {
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        try edit("c.txt", Self.childFile, replacing: 9, with: "c10 fixed")
        try Stack.absorb(repo.context(console: console), [])

        #expect(try repo.subjects("parent") == ["add p", "trunk file", "root"])
        #expect(try repo.subjects("child") == ["add c2", "add c", "add p", "trunk file", "root"])
        #expect(try show("parent", "p.txt").contains("p3 fixed"))
        #expect(try show("child~1", "c.txt").contains("c10 fixed"))
        #expect(try repo.isAncestor("parent", "child"))
        #expect(try repo.loadState()["child"]?.base == (try repo.rev("parent")))
        #expect(try repo.git("diff", "--cached", "--name-only").isEmpty)
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(console.stdout.contains("absorbed p.txt @@ -2,3 +2,3 @@ → "))
        #expect(console.stdout.contains("(parent) add p\n"))
    }

    @Test func unclearHunksStayStagedAndUnstagedEditsAreUntouched() throws {
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        try edit("t.txt", (1 ... 6).map { "t\($0)" }, replacing: 3, with: "t4 edited")
        try write("new.txt", ["new"])
        try repo.git("add", "new.txt")
        try edit("c.txt", Self.childFile, replacing: 5, with: "c6 unstaged", stage: false)
        try Stack.absorb(repo.context(console: console), [])

        #expect(try show("parent", "p.txt").contains("p3 fixed"))
        #expect(try repo.git("diff", "--cached", "--name-only") == "new.txt\nt.txt")
        #expect(try repo.git("diff", "--name-only") == "c.txt")
        #expect(console.stdout.contains("  t.txt @@ -3,3 +3,3 @@: lines last touched outside the stack\n"))
        #expect(console.stdout.contains("  new.txt @@ -0,0 +1 @@: a new file\n"))
    }

    @Test func nothingAbsorbableFails() throws {
        try edit("t.txt", (1 ... 6).map { "t\($0)" }, replacing: 3, with: "t4 edited")
        let before = try repo.rev("child")
        #expect(stackFailure { try Stack.absorb(repo.context(console: console), []) }?.message
            == "no staged hunk has a clear target in the stack")
        #expect(try repo.rev("child") == before)
    }

    @Test func nothingStagedFails() throws {
        #expect(stackFailure { try Stack.absorb(repo.context(), []) }?.message == "nothing staged — `git add` the changes to absorb first")
    }

    @Test func aDryRunMovesNothing() throws {
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        let before = try repo.rev("child")
        try Stack.absorb(repo.context(console: console), ["--dry-run"])
        #expect(try repo.rev("child") == before)
        #expect(console.stdout.hasPrefix("would absorb p.txt @@ -2,3 +2,3 @@ → "))
        #expect(try repo.git("diff", "--cached", "--name-only") == "p.txt")
    }

    @Test func aForkOffARewrittenBranchIsRestacked() throws {
        try repo.git("switch", "-q", "-c", "sibling", "parent")
        try commit("s.txt", ["s"], "add s")
        var state = try repo.loadState()
        state["sibling"] = entry("parent", try repo.rev("parent"))
        try repo.writeState(state)
        try repo.git("switch", "-q", "child")

        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        try Stack.absorb(repo.context(console: console), [])
        #expect(try repo.isAncestor("parent", "sibling"))
        #expect(try repo.subjects("sibling").prefix(2) == ["add s", "add p"])
        #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "child")
        #expect(console.stdout.contains("  sibling: rebased onto parent\n"))
    }

    @Test func undoPutsTheAbsorbedChangesBackInTheIndex() throws {
        let before = try repo.rev("child")
        let parentBefore = try repo.rev("parent")
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        try edit("c.txt", Self.childFile, replacing: 5, with: "c6 unstaged", stage: false)
        try Stack.absorb(repo.context(), [])
        try Stack.undo(repo.context(), [])

        #expect(try repo.rev("child") == before)
        #expect(try repo.rev("parent") == parentBefore)
        #expect(try repo.git("diff", "--cached", "--name-only") == "p.txt")
        #expect(try repo.git("diff", "--name-only") == "c.txt")

        try Stack.undo(repo.context(), [])
        #expect(try show("parent", "p.txt").contains("p3 fixed"))
        #expect(try repo.git("diff", "--cached", "--name-only").isEmpty)
    }

    @Test func undoRefusesAnotherCheckout() throws {
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        try Stack.absorb(repo.context(), [])
        let after = try repo.rev("child")
        try repo.git("switch", "-q", "main")
        let failure = stackFailure { try Stack.undo(repo.context(), []) }
        #expect(failure?.message?.contains("keeps the index, so undo it from") == true)
        #expect(failure?.message?.contains("on 'child'") == true)
        #expect(try repo.rev("child") == after)
    }

    /// `child` cuts the end of `p.txt`, so a fix to its new last line blames
    /// to `parent` but can't apply there, where the file goes on.
    @Test func aHunkThatDoesNotApplyAtItsTargetStaysStaged() throws {
        try commit("p.txt", Array(Self.parentFile.prefix(10)), "cut p")
        try edit("p.txt", Array(Self.parentFile.prefix(10)), replacing: 9, with: "p10 fixed")
        try edit("c.txt", Self.childFile, replacing: 2, with: "c3 fixed")
        try Stack.absorb(repo.context(console: console), ["--dry-run"])
        #expect(console.stdout.contains("  p.txt @@ -9,2 +9,2 @@: doesn't apply at "))
        #expect(console.stdout.contains("would absorb c.txt"))
    }

    @Test func aMergeInProgressIsRefused() throws {
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        let mergeHead = try repo.git("rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD")
        try (try repo.rev("main") + "\n").write(toFile: mergeHead, atomically: true, encoding: .utf8)
        #expect(stackFailure { try Stack.absorb(repo.context(), []) }?.message == "a merge is in progress — finish or abort it first")
    }

    @Test func aFailedAbsorbLeavesNoSnapshot() throws {
        try repo.git("worktree", "add", "-q", "\(repo.directory)/wt-parent", "parent")
        try edit("p.txt", Self.parentFile, replacing: 2, with: "p3 fixed")
        #expect(stackFailure { try Stack.absorb(repo.context(), []) } != nil)
        #expect(try repo.context().undoStore.list().isEmpty)
    }
}

struct StackAbsorbPlannerTests {
    func hunk(_ header: String, _ lines: [String]) -> StackHunk {
        StackPatch.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n\(header)\n" + lines.joined(separator: "\n") + "\n")[0].hunks[0]
    }

    let index = ["a": 0, "b": 1, "c": 2]

    @Test func aRemovalGoesToTheNewestCommitAmongItsLines() {
        let h = hunk("@@ -1,3 +1,3 @@", [" x", "-y", "+y2", " z"])
        #expect(StackAbsorbPlanner.target(h, file: "f", blame: [1: "a", 2: "b", 3: "a"], stackIndex: index).commit == 1)
    }

    @Test func contextChangedLaterIsUnclear() {
        let h = hunk("@@ -1,3 +1,3 @@", [" x", "-y", "+y2", " z"])
        let target = StackAbsorbPlanner.target(h, file: "f", blame: [1: "a", 2: "b", 3: "c"], stackIndex: index)
        #expect(target.commit == nil)
        #expect(target.reason == "its context was changed again later, in c")
    }

    @Test func anInsertionFollowsItsNeighbours() {
        let h = hunk("@@ -4,2 +4,3 @@", [" x", "+new", " z"])
        #expect(StackAbsorbPlanner.target(h, file: "f", blame: [4: "b", 5: "a"], stackIndex: index).commit == 1)
    }

    @Test func linesFromOutsideTheStackAreUnclear() {
        let h = hunk("@@ -1,1 +1,1 @@", ["-y", "+y2"])
        #expect(StackAbsorbPlanner.target(h, file: "f", blame: [1: "trunk"], stackIndex: index).reason == "lines last touched outside the stack")
    }

    @Test func parsesFilesAndKinds() {
        let diff = """
            diff --git a/m b/m
            index 1..2 100644
            --- a/m
            +++ b/m
            @@ -1 +1 @@ func f()
            -a
            +b
            @@ -9,2 +9,0 @@
            -c
            -d
            diff --git a/n b/n
            new file mode 100644
            --- /dev/null
            +++ b/n
            @@ -0,0 +1 @@
            +n
            diff --git a/bin b/bin
            Binary files a/bin and b/bin differ
            diff --git a/x b/x
            old mode 100644
            new mode 100755

            """
        let files = StackPatch.parse(diff)
        #expect(files.map(\.path) == ["m", "n", "bin", "x"])
        #expect(files.map(\.kind) == [.modified, .added, .unsupported("binary or empty"), .unsupported("mode change")])
        #expect(files[0].hunks.map(\.range) == ["@@ -1 +1 @@", "@@ -9,2 +9,0 @@"])
        #expect(files[0].hunks[0].oldCount == 1)
        #expect(files[0].hunks[1].removedOldLines == [9, 10])
        #expect(files[0].patch([files[0].hunks[1]]) == "diff --git a/m b/m\nindex 1..2 100644\n--- a/m\n+++ b/m\n@@ -9,2 +9,0 @@\n-c\n-d\n")
    }

    @Test func aDiffDecodedWithReplacementsIsUnsupported() {
        let files = StackPatch.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+\u{FFFD}\n")
        #expect(files[0].kind == .unsupported(StackDiffFile.Kind.notUTF8))
    }
}
