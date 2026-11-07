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

    private func lineCount(_ content: DiffFileContent) -> Int {
        guard case .text(let hunks) = content else { return 0 }
        return hunks.reduce(0) { $0 + $1.lines.count }
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
            path: "dir with space/untracked file.txt", kind: .added, addedLines: 2, origin: .untracked
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
        #expect(lineCount(uncapped) == 50)
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
        #expect(lineCount(content) == 2)
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
        #expect(GitDiffEngine.defaultBaseRef(in: repository) == .init(ref: "refs/heads/main"))
    }

    @Test func defaultBaseRefKeepsASlashInTheRemoteDefaultBranch() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["update-ref", "refs/remotes/origin/release/2.0", "HEAD"], in: repository)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repository)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/release/2.0"], in: repository)

        let base = GitDiffEngine.defaultBaseRef(in: repository)
        #expect(base.ref == "refs/remotes/origin/release/2.0")
        #expect(base.displayName == "origin/release/2.0")
    }

    @Test func defaultBaseRefSkipsADanglingOriginHead() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repository)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone"], in: repository)

        #expect(GitDiffEngine.defaultBaseRef(in: repository) == .init(ref: "refs/remotes/origin/main"))
    }

    @Test func untrackedFileTooLargeToCountLoadsTooLargeUntilLifted() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("one\ntwo\nthree\n", to: "huge.log", in: repository)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let files = try GitDiffEngine.files(in: range, countingLimit: 4)
        let file = try #require(files.first { $0.path == "huge.log" })
        #expect(file.isUncounted)
        #expect(file.changedLines == 0)

        let capped = try GitDiffEngine.content(for: file, in: range)
        let lifted = try GitDiffEngine.content(for: file, in: range, lineCap: nil)
        #expect(capped == .tooLarge(changedLines: nil))
        #expect(lineCount(lifted) == 3)
    }

    @Test func untrackedSymlinkCountsAsOneLine() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try FileManager.default.createSymbolicLink(atPath: "\(repository)/link", withDestinationPath: "kept.txt")

        let (range, files) = try workingTreeFiles(in: repository)
        let file = try #require(files["link"])
        #expect(file.addedLines == 1)
        let content = try GitDiffEngine.content(for: file, in: range)
        #expect(lineCount(content) == 1)
    }

    @Test func untrackedFIFOIsSkippedWithoutReading() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        #expect(mkfifo("\(repository)/pipe", 0o644) == 0)

        #expect(GitDiffEngine.untrackedSummary(path: "pipe", root: repository) == nil)
        let (_, files) = try workingTreeFiles(in: repository)
        #expect(files["pipe"] == nil)
    }

    @Test func removedFromTheIndexButOnDiskIsOneModification() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["rm", "--cached", "kept.txt"], in: repository)
        try write("one\nTWO\nthree\n", to: "kept.txt", in: repository)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let all = try GitDiffEngine.files(in: range)
        #expect(all.filter { $0.path == "kept.txt" }.count == 1)
        let file = try #require(all.first { $0.path == "kept.txt" })
        #expect(file == DiffFileSummary(
            path: "kept.txt", kind: .modified, addedLines: 1, removedLines: 1, origin: .untrackedOverBase
        ))

        let content = try GitDiffEngine.content(for: file, in: range)
        guard case .text(let hunks) = content else {
            Issue.record("expected text, got \(content)")
            return
        }
        let changed = hunks.flatMap(\.lines).filter { $0.kind != .context }
        #expect(changed == [
            DiffLine(kind: .removed, text: "two", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .added, text: "TWO", oldNumber: nil, newNumber: 2),
        ])
    }

    @Test func crlfLinesLoadWithoutTheCarriageReturn() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("a\r\nb\r\n", to: "dos.txt", in: repository)
        try git(["add", "dos.txt"], in: repository)
        try git(["commit", "-m", "dos"], in: repository)
        try write("a\r\nc\r\n", to: "dos.txt", in: repository)

        let (range, files) = try workingTreeFiles(in: repository)
        let file = try #require(files["dos.txt"])
        let content = try GitDiffEngine.content(for: file, in: range)
        guard case .text(let hunks) = content else {
            Issue.record("expected text, got \(content)")
            return
        }
        #expect(hunks.flatMap(\.lines).map(\.text) == ["a", "b", "c"])
    }

    @Test func snapshotListsTrackedAndUntrackedButNotIgnored() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("build/\n", to: ".gitignore", in: repository)
        try write("x\n", to: "build/out.o", in: repository)
        try write("y\n", to: "fresh.txt", in: repository)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let snapshot = try GitDiffEngine.snapshot(in: range)
        #expect(Set(snapshot.listedPaths) == [
            ".gitignore", "doomed.txt", "fresh.txt", "kept.txt", "old name.txt", "tail.txt",
        ])
        #expect(snapshot.listedPaths.count == Set(snapshot.listedPaths).count)
    }

    @Test func unignoredPathsDropIgnoredButKeepTrackedOnes() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("build/\n*.txt\n", to: ".gitignore", in: repository)

        let kept = try GitDiffEngine.unignoredPaths(
            ["build/out.o", "src/a.swift", "kept.txt", "new.txt"],
            in: repository
        )
        let noneIgnored = try GitDiffEngine.unignoredPaths(["src/a.swift"], in: repository)
        #expect(kept == ["src/a.swift", "kept.txt"])
        #expect(noneIgnored == ["src/a.swift"])
    }

    @Test func watchScopeFindsALinkedWorktreesGitDirectories() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let worktree = repository + "-wt"
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        try git(["worktree", "add", "-b", "topic", worktree], in: repository)

        let scope = try RepositoryWatchScope.resolve(in: worktree)
        let common = RepositoryWatchScope.realPath(repository) + "/.git"
        #expect(scope.root == RepositoryWatchScope.realPath(worktree))
        #expect(scope.commonDirectory == common)
        #expect(scope.gitDirectory.hasPrefix(common + "/worktrees/"))
        #expect(scope.watchedPaths == [scope.root, common])

        #expect(scope.classify(scope.gitDirectory + "/index") == .index)
        #expect(scope.classify(scope.gitDirectory + "/HEAD") == .ref("HEAD"))
        #expect(scope.classify(common + "/refs/remotes/origin/main") == .ref("refs/remotes/origin/main"))
        #expect(scope.classify(common + "/packed-refs") == .ref("packed-refs"))
        #expect(scope.classify(common + "/HEAD") == .irrelevant)
        #expect(scope.classify(common + "/objects/ab/cdef") == .irrelevant)
        #expect(scope.classify(common + "/index") == .irrelevant)
        #expect(scope.classify(scope.root + "/src/a.swift") == .workingTree("src/a.swift"))
        #expect(scope.classify(scope.root + "/vendor/.git/index") == .irrelevant)
        #expect(scope.classify(common + "/config") == .baseSettings)
        #expect(scope.classify(common + "/stack/branches.json") == .baseSettings)
        #expect(scope.classify(scope.gitDirectory + "/config.worktree") == .irrelevant)
    }

    @Test func baseOptionsReadTheStackParentAndUpstream() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["branch", "parent"], in: repository)
        try git(["branch", "child"], in: repository)
        try git(["config", "branch.child.remote", "."], in: repository)
        try git(["config", "branch.child.merge", "refs/heads/main"], in: repository)
        try write(
            #"{"version": 2, "branches": {"parent": {"parent": "main", "base": "x"}, "child": {"parent": "parent", "base": "y"}}}"#,
            to: ".git/stack/branches.json",
            in: repository
        )

        let child = GitDiffEngine.baseOptions(in: repository, headRef: "refs/heads/child")
        #expect(child.stackParent == "refs/heads/parent")
        #expect(child.upstream == "refs/heads/main")
        #expect(child.defaultBase == .stackParent)
        #expect(child.available == [.stackParent, .originDefault, .upstream, .head])

        let parent = GitDiffEngine.baseOptions(in: repository, headRef: "refs/heads/parent")
        #expect(parent.stackParent == nil)
        #expect(parent.defaultBase == .originDefault)
    }

    @Test func headAndPreviousCommitBasesReadNoMergeBase() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write("one\ntwo\nthree\nfour\n", to: "kept.txt", in: repository)
        try git(["commit", "-am", "next"], in: repository)
        let options = GitDiffEngine.baseOptions(in: repository, headRef: "refs/heads/main")
        let head = try git(["rev-parse", "HEAD"], in: repository)
        let previous = try git(["rev-parse", "HEAD~1"], in: repository)

        let headRange = try GitDiffEngine.resolveWorkingTree(base: .head, options: options, root: repository)
        #expect(headRange.baseCommit == head)
        #expect(try GitDiffEngine.files(in: headRange).isEmpty)

        let previousRange = try GitDiffEngine.resolveWorkingTree(base: .previousCommit, options: options, root: repository)
        #expect(previousRange.baseCommit == previous)
        let files = try GitDiffEngine.files(in: previousRange)
        #expect(files.map(\.path) == ["kept.txt"])
    }

    @Test func watchScopeOfAPlainCheckoutWatchesOnlyTheRoot() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let scope = try RepositoryWatchScope.resolve(in: repository)
        #expect(scope.watchedPaths == [scope.root])
        #expect(scope.classify(scope.root + "/.git/index") == .index)
        #expect(scope.classify(scope.root + "/.git/refs/heads/main") == .ref("refs/heads/main"))
        #expect(scope.classify(scope.root + "/.git/objects/ab/cdef") == .irrelevant)
    }

    /// The alias's shell holds stderr after git closes stdout, so a runner that
    /// read stderr only after stdout would block until the timeout.
    @Test func stderrFloodDoesNotDeadlock() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try GitRunner.run(
            ["-c", "alias.spam=!exec >/dev/null; yes x | head -c 400000 >&2", "spam"],
            in: repository,
            timeout: .seconds(10)
        )
    }

    @Test func untrackedCountsComeFromTheCacheUntilSizeOrTimeMoves() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let path = "\(repository)/notes.txt"
        let fixed = Date(timeIntervalSince1970: 1_000_000)
        try write("a\nb\n", to: "notes.txt", in: repository)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: path)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let cache = UntrackedCountCache()
        let first = try GitDiffEngine.files(in: range, cache: cache).first { $0.path == "notes.txt" }

        // Same size and time with different lines, so only a cache hit says 2.
        try write("abcd", to: "notes.txt", in: repository)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: path)
        let cached = try GitDiffEngine.files(in: range, cache: cache).first { $0.path == "notes.txt" }

        try FileManager.default.setAttributes([.modificationDate: fixed.addingTimeInterval(1)], ofItemAtPath: path)
        let recounted = try GitDiffEngine.files(in: range, cache: cache).first { $0.path == "notes.txt" }

        #expect(first?.addedLines == 2)
        #expect(cached?.addedLines == 2)
        #expect(recounted?.addedLines == 1)
    }

    @Test func nestedRepositoriesAndSubmodulesAreListedAndTheirWritesIgnored() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try git(["init", "-b", "main", "nested"], in: repository)
        try write("inner\n", to: "nested/inner.txt", in: repository)
        let head = try git(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-index", "--add", "--cacheinfo", "160000,\(head),sub"], in: repository)

        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: repository)
        let snapshot = try GitDiffEngine.snapshot(in: range)
        #expect(snapshot.listedPaths.contains("nested/"))
        #expect(!snapshot.files.contains { $0.path.hasPrefix("nested") })
        #expect(snapshot.nestedRepositories == ["nested", "sub"])

        let triage = ReviewChangeTriage(
            knownPaths: Set(snapshot.listedPaths),
            nestedRepositories: snapshot.nestedRepositories
        )
        let outcome = triage.triage([.workingTree("nested/inner.txt"), .workingTree("sub/x.txt")])
        #expect(outcome == .init())
    }
}

