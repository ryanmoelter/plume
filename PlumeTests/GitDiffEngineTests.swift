import Foundation
import Testing
@testable import Plume

/// Runs the engine against scratch repositories: a `main` with one commit, and
/// a `feature` branch whose committed, staged, unstaged and untracked changes
/// a working-tree review must all show.
struct GitDiffEngineTests {
    private func makeRepository() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-diff-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: path)
        try git(["config", "user.email", "test@example.com"], in: path)
        try git(["config", "user.name", "Test"], in: path)
        try git(["config", "commit.gpgsign", "false"], in: path)
        try write("one\ntwo\nthree\n", to: "kept.txt", in: path)
        try write("a\nb\nc\nd\ne\nf\ng\nh\n", to: "old name.txt", in: path)
        try write("doomed\n", to: "doomed.txt", in: path)
        try write("no newline", to: "tail.txt", in: path)
        try git(["add", "."], in: path)
        try git(["commit", "-m", "init"], in: path)
        return path
    }

    @discardableResult
    private func git(_ arguments: [String], in path: String) throws -> String {
        try GitRunner.run(arguments, in: path)
    }

    private func write(_ text: String, to name: String, in root: String) throws {
        let url = URL(fileURLWithPath: root).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func workingTreeFiles(in repository: String) throws -> (ResolvedDiffRange, [String: DiffFileSummary]) {
        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let files = try GitDiffEngine.files(in: range)
        return (range, Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }))
    }

    @Test func workingTreeRangeCoversCommittedStagedUnstagedAndUntracked() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["checkout", "-b", "feature"], in: repository)

        try write("one\ntwo\nthree\nfour\n", to: "kept.txt", in: repository)
        try git(["commit", "-am", "committed"], in: repository)
        try git(["mv", "old name.txt", "new name.txt"], in: repository)
        try git(["rm", "-q", "doomed.txt"], in: repository)
        try write("one\nTWO\nthree\nfour\n", to: "kept.txt", in: repository)
        try write("fresh\nlines\n", to: "dir with space/untracked file.txt", in: repository)

        let (range, files) = try workingTreeFiles(in: repository)

        #expect(range.revisions.count == 1)
        #expect(files["kept.txt"] == DiffFileSummary(path: "kept.txt", kind: .modified, addedLines: 2, removedLines: 1))
        #expect(files["new name.txt"] == DiffFileSummary(path: "new name.txt", oldPath: "old name.txt", kind: .renamed))
        #expect(files["doomed.txt"] == DiffFileSummary(path: "doomed.txt", kind: .deleted, removedLines: 1))
        #expect(files["dir with space/untracked file.txt"] == DiffFileSummary(
            path: "dir with space/untracked file.txt", kind: .added, addedLines: 2, isUntracked: true
        ))
        #expect(files.count == 4)
    }

    @Test func mergeBaseIgnoresCommitsLandingOnTheBaseAfterwards() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["checkout", "-b", "feature"], in: repository)
        try write("feature\n", to: "feature.txt", in: repository)
        try git(["add", "."], in: repository)
        try git(["commit", "-m", "feature"], in: repository)
        try git(["checkout", "-q", "main"], in: repository)
        try write("main moved on\n", to: "main-only.txt", in: repository)
        try git(["add", "."], in: repository)
        try git(["commit", "-m", "main"], in: repository)
        try git(["checkout", "-q", "feature"], in: repository)

        let (_, files) = try workingTreeFiles(in: repository)

        #expect(Set(files.keys) == ["feature.txt"])
    }

    @Test func renamedFileLoadsAsOneHunkAcrossBothPaths() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["mv", "old name.txt", "new name.txt"], in: repository)
        try write("a\nb\nc\nd\ne\nf\ng\nH\n", to: "new name.txt", in: repository)

        let (range, files) = try workingTreeFiles(in: repository)
        let renamed = try #require(files["new name.txt"])
        #expect(renamed.kind == .renamed)

        let content = try GitDiffEngine.content(for: renamed, in: range)
        guard case .text(let hunks) = content else {
            Issue.record("expected text, got \(content)")
            return
        }
        let changed = hunks.flatMap(\.lines).filter { $0.kind != .context }
        #expect(changed.map(\.text) == ["h", "H"])
        #expect(changed.map(\.oldNumber) == [8, nil])
        #expect(changed.map(\.newNumber) == [nil, 8])
    }

    @Test func noNewlineAtEndOfFileIsMarked() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("no newline, changed", to: "tail.txt", in: repository)

        let (range, files) = try workingTreeFiles(in: repository)
        let content = try GitDiffEngine.content(for: try #require(files["tail.txt"]), in: range)
        guard case .text(let hunks) = content else {
            Issue.record("expected text, got \(content)")
            return
        }
        #expect(hunks[0].lines.map(\.missingNewline) == [true, true])
    }

    @Test func binaryFilesAreFlaggedTrackedOrNot() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])
        try bytes.write(to: URL(fileURLWithPath: repository).appending(path: "tracked.bin"))
        try git(["add", "tracked.bin"], in: repository)
        try git(["commit", "-m", "binary"], in: repository)
        try (bytes + Data([0x03])).write(to: URL(fileURLWithPath: repository).appending(path: "tracked.bin"))
        try bytes.write(to: URL(fileURLWithPath: repository).appending(path: "untracked.bin"))

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "HEAD~1"), in: repository)
        let files = Dictionary(uniqueKeysWithValues: try GitDiffEngine.files(in: range).map { ($0.path, $0) })

        let tracked = try #require(files["tracked.bin"])
        let untracked = try #require(files["untracked.bin"])
        #expect(tracked.isBinary)
        #expect(untracked.isBinary)
        let trackedContent = try GitDiffEngine.content(for: tracked, in: range)
        let untrackedContent = try GitDiffEngine.content(for: untracked, in: range)
        #expect(trackedContent == .binary)
        #expect(untrackedContent == .binary)
    }

    @Test func untrackedFileLoadsAsAllAdded() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("first\nsecond", to: "sub dir/new file.txt", in: repository)

        let (range, files) = try workingTreeFiles(in: repository)
        let file = try #require(files["sub dir/new file.txt"])
        #expect(file.addedLines == 2)

        let content = try GitDiffEngine.content(for: file, in: range)
        guard case .text(let hunks) = content else {
            Issue.record("expected text, got \(content)")
            return
        }
        #expect(hunks.flatMap(\.lines) == [
            DiffLine(kind: .added, text: "first", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .added, text: "second", oldNumber: nil, newNumber: 2, missingNewline: true),
        ])
    }

    @Test func largeFileHitsTheCapUnlessLifted() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(body, to: "big.txt", in: repository)
        try git(["add", "big.txt"], in: repository)

        let (range, files) = try workingTreeFiles(in: repository)
        let file = try #require(files["big.txt"])

        let capped = try GitDiffEngine.content(for: file, in: range, lineCap: 10)
        let uncapped = try GitDiffEngine.content(for: file, in: range, lineCap: nil)
        #expect(capped == .tooLarge(changedLines: 50))
        #expect(uncapped.lineCount == 50)
    }

    @Test func pathsThatLookLikePathspecMagicLoadLiterally() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("x\n", to: "*.txt", in: repository)
        try git(["--literal-pathspecs", "add", "*.txt"], in: repository)
        try git(["commit", "-m", "glob"], in: repository)
        try write("y\n", to: "*.txt", in: repository)
        try write("one\ntwo\nTHREE\n", to: "kept.txt", in: repository)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "HEAD"), in: repository)
        let files = Dictionary(uniqueKeysWithValues: try GitDiffEngine.files(in: range).map { ($0.path, $0) })
        let glob = try #require(files["*.txt"])

        let content = try GitDiffEngine.content(for: glob, in: range)
        #expect(content.lineCount == 2)
    }

    @Test func singleCommitRangeDiffsAgainstItsParent() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("added\n", to: "later.txt", in: repository)
        try git(["add", "."], in: repository)
        try git(["commit", "-m", "later"], in: repository)

        let range = try GitDiffEngine.resolve(.commit("HEAD"), in: repository)
        let paths = try GitDiffEngine.files(in: range).map(\.path)
        #expect(paths == ["later.txt"])
    }

    @Test func rootCommitRangeDiffsAgainstTheEmptyTree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let range = try GitDiffEngine.resolve(.commit("HEAD"), in: repository)
        let files = try GitDiffEngine.files(in: range)
        #expect(files.count == 4)
        #expect(files.allSatisfy { $0.kind == .added })
    }

    @Test func commitsRangeExcludesTheWorkingTree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("added\n", to: "later.txt", in: repository)
        try git(["add", "."], in: repository)
        try git(["commit", "-m", "later"], in: repository)
        try write("dirty\n", to: "kept.txt", in: repository)
        try write("untracked\n", to: "loose.txt", in: repository)

        let range = try GitDiffEngine.resolve(.commits(base: "HEAD~1", head: "HEAD"), in: repository)
        let paths = try GitDiffEngine.files(in: range).map(\.path)
        #expect(paths == ["later.txt"])
    }

    @Test func defaultBaseRefFallsBackToALocalBranch() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        #expect(GitDiffEngine.defaultBaseRef(in: repository) == "main")
    }
}
