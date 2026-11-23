import Foundation
import Testing
@testable import Plume

/// `stack split --hunks` cuts the uncommitted changes into new stacked
/// branches, one commit each, and leaves unassigned hunks in the tree.
struct StackSplitHunksTests {
    let repo: StackScratchRepo
    let console = BufferConsole()
    static let lines = (1 ... 12).map { "l\($0)" }

    /// `feat` on `main`, with `f.txt` holding twelve lines.
    init() throws {
        repo = try StackScratchRepo()
        try repo.pushTrunk()
        try repo.git("switch", "-qc", "feat")
        try repo.write("f.txt", Self.lines.joined(separator: "\n") + "\n")
        try repo.git("add", "f.txt")
        try repo.git("commit", "-q", "-m", "add f")
        try repo.writeState(["feat": entry("main", try repo.rev("main"))])
    }

    /// Edits lines 2 and 10 of `f.txt` (two hunks) and adds untracked `n.txt`.
    func makeChanges() throws {
        var lines = Self.lines
        lines[1] = "l2 changed"
        lines[9] = "l10 changed"
        try repo.write("f.txt", lines.joined(separator: "\n") + "\n")
        try repo.write("n.txt", "new\n")
    }

    func split(_ arguments: [String]) throws {
        try Stack.split(repo.context(console: console), ["--hunks"] + arguments)
    }

    @Test func listsTheHunksNumbered() throws {
        try makeChanges()
        try split([])
        #expect(console.stdout == """
            uncommitted hunks on 'feat' (assign them with `stack split --hunks --map <json>`):
               1  f.txt @@ -1,3 +1,3 @@  (+1 -1)
               2  f.txt @@ -9,3 +9,3 @@  (+1 -1)
               3  n.txt @@ -0,0 +1 @@  (+1 -0)

            """)
    }

    @Test func listsTheHunksAsJSON() throws {
        try makeChanges()
        try split(["--json"])
        let document = try StackJSON.parse(Data(console.stdout.utf8))
        guard case .array(let hunks)? = document["hunks"] else { Issue.record("no hunks"); return }
        #expect(hunks.count == 3)
        #expect(hunks[2]["file"] == .string("n.txt"))
        #expect(hunks[0]["lines"] == .array([" l1", "-l2", "+l2 changed", " l3"].map(StackJSON.string)))
    }

    @Test func aMapMakesOneStackedBranchPerEntry() throws {
        try makeChanges()
        let feat = try repo.rev("feat")
        try split(["--map", #"[{"branch": "lower", "hunks": [2], "message": "Fix l10"}, {"branch": "upper", "hunks": ["n.txt"]}]"#])

        #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "upper")
        #expect(try repo.subjects("upper").prefix(3) == ["upper", "Fix l10", "add f"])
        #expect(try repo.git("show", "lower:f.txt").contains("l10 changed"))
        #expect(try !repo.git("show", "lower:f.txt").contains("l2 changed"))
        #expect(try repo.git("show", "upper:n.txt") == "new")
        #expect(try repo.git("status", "--porcelain") == "M f.txt")
        #expect(try repo.git("diff").contains("+l2 changed"))
        #expect(try repo.read("f.txt").contains("l10 changed"))
        let state = try repo.loadState()
        #expect(state["lower"] == entry("feat", feat))
        #expect(state["upper"] == entry("lower", try repo.rev("lower")))
        #expect(console.stdout.hasPrefix("split the uncommitted changes into: lower (1 hunk(s)) ← upper (1 hunk(s))\n1 hunk(s) left uncommitted on 'upper'\n"))
    }

    @Test func undoPutsTheChangesBack() throws {
        try makeChanges()
        try split(["--map", #"[{"branch": "lower", "hunks": [1, 2]}]"#])
        try Stack.undo(repo.context(), [])
        #expect(try repo.git("symbolic-ref", "--short", "HEAD") == "feat")
        #expect(try !repo.localBranches().contains("lower"))
        #expect(try repo.loadState() == ["feat": entry("main", try repo.rev("main"))])
        #expect(try repo.read("f.txt").contains("l2 changed"))
        #expect(try repo.git("diff", "HEAD", "--name-only") == "f.txt")
    }

    @Test func refusals() throws {
        #expect(stackFailure { try split([]) }?.message == "no uncommitted changes to split")
        try makeChanges()
        #expect(stackFailure { try split(["--map", #"[{"branch": "a", "hunks": [9]}]"#]) }?.message == "'a': no hunk 9")
        #expect(stackFailure { try split(["--map", #"[{"branch": "a", "hunks": [1]}, {"branch": "b", "hunks": ["f.txt"]}]"#]) }?.message
            == "hunk 1 is assigned to both 'a' and 'b'")
        #expect(stackFailure { try split(["--map", #"[{"branch": "feat", "hunks": [1]}]"#]) }?.message == "branch 'feat' already exists")
        #expect(stackFailure { try split(["--map", "{}"]) }?.message?.hasPrefix("--map must be a non-empty array") == true)
        #expect(stackFailure { try split(["--map", "[{"]) }?.message?.hasPrefix("--map is not valid JSON") == true)
        #expect(try repo.localBranches() == ["feat", "main"])
    }

    @Test func aMapCanComeFromAFile() throws {
        try makeChanges()
        let path = "\(repo.directory)/map.json"
        try #"[{"branch": "all", "hunks": [1, 2, 3]}]"#.write(toFile: path, atomically: true, encoding: .utf8)
        try split(["--map", path])
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(!console.stdout.contains("left uncommitted"))
    }
}
