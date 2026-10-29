import Foundation
import Testing
@testable import Plume

/// The state file: loading, the prune of deleted branches, and that the
/// prune lands on disk on the first load that notices it rather than being
/// recomputed, and re-warned, on every command.
///
/// A three-branch stack, main → a → b → c, whose middle branch can be made
/// to look deleted.
struct StackStateTests {
    let directory: String
    let git: FakeStackGit
    let console = BufferConsole()
    let state: StackBranches = [
        "a": entry("main", "m0"),
        "b": entry("a", "a1"),
        "c": entry("b", "b1"),
    ]

    init() throws {
        directory = try makeScratchDirectory() + "/stack"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        git = FakeStackGit(
            tips: ["main": "m0", "a": "a1", "b": "b1", "c": "c1"],
            ancestors: linearHistory("m0", "a1", "b1", "c1")
        )
    }

    var ctx: StackContext { stackContext(git, console: console, stateDirectory: directory) }
    var stateFile: String { "\(directory)/branches.json" }

    func write(_ text: String, to name: String = "branches.json") throws {
        try text.write(toFile: "\(directory)/\(name)", atomically: true, encoding: .utf8)
    }

    func write(_ branches: StackBranches) throws {
        try write(StackStateCodec.encode(branches))
    }

    func onDisk() throws -> [String: StackEntry] {
        let records = try StackStateCodec.decode(Data(contentsOf: URL(fileURLWithPath: stateFile)))
        return Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.entry) })
    }

    func modified(_ path: String) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
    }

    @Test func aFailedBranchListingLeavesTheStateAlone() throws {
        try write(state)
        let notARepository = try makeScratchDirectory()
        let broken = stackContext(
            ProcessStackGit(workingDirectory: notARepository),
            console: console,
            stateDirectory: directory
        )
        #expect(stackFailure { _ = try broken.loadAndFlush() } != nil)
        #expect(try onDisk() == state)
    }

    @Test func pruneIsWrittenBack() throws {
        try write(state)
        git.branches.remove("b")
        let branches = try ctx.loadAndFlush()
        #expect(branches["b"] == nil)
        #expect(try onDisk()["b"] == nil)
    }

    @Test func pruneWarnsOnlyOnce() throws {
        try write(state)
        git.branches.remove("b")
        _ = try ctx.loadAndFlush()
        #expect(console.stderr == "stack: pruned deleted branch 'b' from stack state\n")
        _ = try ctx.loadAndFlush()
        #expect(console.stderr == "stack: pruned deleted branch 'b' from stack state\n")
    }

    /// `c` inherits `b`'s parent and keeps its base at `b`'s old tip.
    @Test func reparentingSurvivesTheRoundTrip() throws {
        try write(state)
        git.branches.remove("b")
        _ = try ctx.loadAndFlush()
        #expect(try onDisk()["c"] == entry("a", "b1"))
    }

    @Test func cleanStateIsNotRewritten() throws {
        try write(state)
        let before = try modified(stateFile)
        Thread.sleep(forTimeInterval: 0.01)
        let branches = try ctx.loadAndFlush()
        #expect(branches.keys.sorted() == ["a", "b", "c"])
        #expect(console.stderr.isEmpty)
        #expect(try modified(stateFile) == before)
    }

    /// The mutating commands call this with the lock already held.
    @Test func lockedVariantDoesNotDeadlock() throws {
        try write(state)
        git.branches.remove("b")
        let ctx = self.ctx
        let branches = try ctx.state.withLock { try ctx.loadAndFlushLocked() }
        #expect(branches["b"] == nil)
        #expect(try onDisk()["b"] == nil)
    }

    /// `__complete` runs on every Tab press, so it stays silent and
    /// read-only.
    @Test func completionNeitherWritesNorWarns() throws {
        try write(state)
        git.branches.remove("b")
        let before = try modified(stateFile)
        try Stack.complete(ctx, ["stack-branches"])
        #expect(console.stderr.isEmpty)
        #expect(try modified(stateFile) == before)
        #expect(console.stdout == "a\nc\n")
    }

    @Test func savingNothingRemovesTheFile() throws {
        try write(state)
        try ctx.state.save([:]) { _ in }
        #expect(!FileManager.default.fileExists(atPath: stateFile))
    }

    @Test func saveWritesAtomicallyAndLeavesNoTemporaryFiles() throws {
        try ctx.state.save(state) { _ in }
        #expect(try onDisk() == state)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix(".branches.") }
        #expect(leftovers.isEmpty)
    }

    /// The one-file-per-stack layout: every `*.json` merges in filename
    /// order, the first entry for a branch wins, and the next save retires
    /// the legacy files.
    @Test func legacyFilesMergeAndRetire() throws {
        try write(#"{"version": 2, "branches": {"a": {"parent": "main", "base": "m0"}}}"#, to: "1-first.json")
        try write(#"{"version": 2, "branches": {"a": {"parent": "x", "base": "x0"}, "b": {"parent": "a", "base": "a1"}}}"#, to: "2-second.json")
        let branches = try ctx.loadAndFlush()
        #expect(branches == ["a": entry("main", "m0"), "b": entry("a", "a1")])
        #expect(console.stderr == "stack: branch 'a' appears in multiple state files — keeping the first entry\n")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }
        #expect(files == ["branches.json"])
    }

    @Test func aNewerStateFileStopsTheCommand() throws {
        try write(#"{"version": 3, "branches": {}}"#)
        let failure = stackFailure { _ = try ctx.loadAndFlush() }
        #expect(failure?.message == "\(stateFile) has state version 3 — this stack binary is too old")
    }

    /// An unreadable file is skipped with a warning, and the next save moves
    /// it aside rather than overwriting it.
    @Test func anUnreadableFileIsKeptAside() throws {
        try write("{not json")
        let branches = try ctx.loadAndFlush()
        #expect(branches.isEmpty)
        #expect(console.stderr.hasPrefix("stack: ignoring unreadable state file \(stateFile): "))
        try ctx.state.save(state) { _ in }
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasPrefix("branches.json.unreadable-") }
        #expect(aside.count == 1)
        #expect(try String(contentsOfFile: "\(directory)/\(aside[0])", encoding: .utf8) == "{not json")
        #expect(try onDisk() == state)
    }
}
