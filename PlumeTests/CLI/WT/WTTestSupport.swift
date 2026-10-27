import Darwin
import Foundation
import Testing
@testable import Plume

// MARK: Rows and PRs shared by the list tests

enum WTFixtures {
    static let githubIcon = "\u{F09B}"
    static let gitlabIcon = "\u{F296}"

    static let rows: [WorktreeRow] = [
        wtRow("dotfiles", "main", "4", dirty: true, remoteAhead: 2, remoteBehind: 1),
        wtRow("scratch", "ryanm/scratch", ""),
        wtRow("det", "abc123 (detached)", "0", hasUpstream: false),
    ]

    /// Parallel to `rows`, since worktree names are not unique.
    static let paths = ["/repo", "/repo/.plume/worktrees/scratch", "/repo/.plume/worktrees/det"]

    static let openPR = PullRequest(number: 7, state: .open, isDraft: false)
    static let closedPR = PullRequest(number: 3, state: .closed, isDraft: false)
}

func wtRow(
    _ name: String,
    _ branch: String,
    _ ahead: String,
    dirty: Bool = false,
    remoteAhead: Int = 0,
    remoteBehind: Int = 0,
    hasUpstream: Bool = true
) -> WorktreeRow {
    WorktreeRow(
        name: name, branch: branch, ahead: ahead, dirty: dirty,
        remoteAhead: remoteAhead, remoteBehind: remoteBehind, hasUpstream: hasUpstream
    )
}

enum ANSI {
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let magenta = "\u{1B}[35m"
    static let reset = "\u{1B}[0m"

    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

/// `git worktree list --porcelain` text from (path, branch) pairs, `nil`
/// standing for a detached HEAD.
func porcelain(_ records: [(String, String?)]) -> String {
    records.map { path, branch in
        let ref = branch.map { "branch refs/heads/\($0)" } ?? "detached"
        return "worktree \(path)\nHEAD \(String(repeating: "a", count: 40))\n\(ref)\n"
    }.joined(separator: "\n")
}

/// The failure `body` throws, or nil when it throws nothing (or something
/// that isn't a `CLIFailure`).
func cliFailure(_ body: () throws -> Void) -> CLIFailure? {
    do {
        try body()
        return nil
    } catch let failure as CLIFailure {
        return failure
    } catch {
        return nil
    }
}

/// The JSON object `text` holds, for comparison against an expected
/// dictionary. `NSNull` stands for `null`.
func jsonObject(_ text: String) -> NSDictionary? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

// MARK: Git

/// Every git call `wt` makes, answered from memory. Mutating calls are
/// recorded and succeed.
nonisolated final class FakeWorktreeGit: WorktreeGit {
    struct AddedWorktree: Equatable {
        var path: String
        var branch: String
        var new: Bool
        var baseRef: String?
    }

    var repoDir: String?
    var entries: [WorktreeEntry]
    var top: String?
    var common: String?
    var config: [String: String]
    var origin: String?
    var head: String?
    var branches: Set<String>
    /// Branches `isAncestor` reports as merged into anything.
    var merged: Set<String>
    var branchByPath: [String: String]
    var statusLines: [String: [String]]
    /// Tags, each an ancestor of everything: a bare name in a revision position
    /// resolves to the tag before the branch, as git does.
    var tags: Set<String> = []
    /// What `revParse` answers, by ref.
    var shas: [String: String] = [:]
    var dirtyPaths: Set<String> = []
    /// Paths whose `isClean` fails, as a deleted folder's does.
    var unreadablePaths: Set<String> = []
    var stashRestoreSucceeds = true
    var worktreeAddSucceeds = true
    /// Paths whose `worktreeRemove` fails, as a locked worktree's does.
    var unremovablePaths: Set<String> = []
    /// Branches whose deletion fails.
    var undeletableBranches: Set<String> = []
    /// Which checkouts fail, by path, ref and whether detached.
    var checkoutFails: (_ path: String, _ ref: String, _ detach: Bool) -> Bool = { _, _, _ in false }

    private(set) var added: [AddedWorktree] = []
    private(set) var fetched: [String] = []
    private(set) var removed: [String] = []
    private(set) var stashes: [(path: String, sha: String)] = []
    private(set) var restoredStashes: [(path: String, sha: String)] = []

    init(
        entries: [WorktreeEntry] = [],
        top: String? = nil,
        common: String? = nil,
        config: [String: String] = [:],
        origin: String? = nil,
        head: String? = nil,
        branches: Set<String> = [],
        merged: Set<String> = [],
        branchByPath: [String: String] = [:],
        statusLines: [String: [String]] = [:]
    ) {
        self.entries = entries
        self.top = top
        self.common = common
        self.config = config
        self.origin = origin
        self.head = head
        self.branches = branches
        self.merged = merged
        self.branchByPath = branchByPath
        self.statusLines = statusLines
    }

    convenience init(_ entries: [(String, String?)], top: String? = nil) {
        self.init(entries: entries.map { WorktreeEntry(path: $0.0, branch: $0.1) }, top: top)
    }

    /// No `.bare` lives here, so `locate` falls through to `top`.
    var workingDirectoryPath = "/nonexistent-wt-fake"
    func toplevel() -> String? { top }
    func commonDir(root: String) -> String? { common }
    func configGet(_ key: String) -> String? { config[key] }
    func originURL() -> String? { origin }
    func originHead() -> String? { head }
    func branchExists(_ branch: String) -> Bool { branches.contains(branch) }
    func refExists(_ ref: String) -> Bool { branches.contains(ref) }
    func isAncestor(_ ref: String, of other: String) -> Bool {
        if tags.contains(ref) { return true }
        return merged.contains(ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref)
    }
    func revParse(_ ref: String) -> String? { shas[ref] ?? (tags.contains(ref) ? "tag-\(ref)" : nil) }
    func localBranches() -> [String] { branches.sorted() }
    func worktreeEntries() -> [WorktreeEntry] { entries }
    func fetchBase(_ baseBranch: String, quiet: Bool) throws { fetched.append(baseBranch) }
    func worktreeAdd(path: String, branch: String, new: Bool, baseRef: String?, fatal: Bool) throws -> Bool {
        guard worktreeAddSucceeds else {
            if fatal { throw CLIFailure(nil, code: 128) }
            return false
        }
        added.append(AddedWorktree(path: path, branch: branch, new: new, baseRef: baseRef))
        return true
    }
    func worktreeRemove(path: String, force: Bool) throws {
        if unremovablePaths.contains(path) { throw CLIFailure(nil, code: 128) }
        removed.append(path)
    }
    func branchDelete(_ branch: String, force: Bool) throws {
        if undeletableBranches.contains(branch) { throw CLIFailure(nil, code: 1) }
        branches.remove(branch)
    }
    func branchDeleteOK(_ branch: String, force: Bool) -> Bool {
        !undeletableBranches.contains(branch) && branches.remove(branch) != nil
    }
    func worktreeMove(from: String, to: String) throws {}
    func branchOf(_ path: String) throws -> String {
        guard let branch = branchByPath[path] else { throw CLIFailure(nil) }
        return branch
    }
    func isClean(_ path: String) throws -> Bool {
        if unreadablePaths.contains(path) { throw CLIFailure(nil, code: 128) }
        return !dirtyPaths.contains(path)
    }
    func statusV2Lines(_ path: String) -> [String] { statusLines[path] ?? [] }
    func shortHead(_ path: String) -> String? { "abc123" }
    func aheadCount(_ path: String, baseRef: String) -> String { "" }
    func checkoutOK(_ path: String, ref: String, detach: Bool, silent: Bool) -> Bool {
        !checkoutFails(path, ref, detach)
    }
    func checkoutFatal(_ path: String, ref: String, detach: Bool, quietStdout: Bool) throws {
        if checkoutFails(path, ref, detach) { throw CLIFailure(nil, code: 1) }
    }
    func stashPush(_ path: String, message: String) throws -> String {
        let sha = "stash-\(stashes.count + 1)"
        stashes.append((path, sha))
        return sha
    }
    func stashRestoreOK(_ path: String, sha: String, silent: Bool) -> Bool {
        restoredStashes.append((path, sha))
        return stashRestoreSucceeds
    }
    func branchMove(_ path: String, from: String, to: String) throws {}
    func commitAll(_ path: String, extraArguments: [String]) -> Int32 { 0 }
    func enableUntrackedCache(_ path: String) {}
}

// MARK: Tabs

nonisolated final class RecordingTabOpener: TabOpener {
    struct Opened: Equatable {
        var directory: String
        var asTask: Bool
    }

    var canOpenTabs: Bool
    private(set) var opened: [Opened] = []

    init(canOpenTabs: Bool = true) {
        self.canOpenTabs = canOpenTabs
    }

    func open(_ directory: String, asTask: Bool) {
        opened.append(Opened(directory: directory, asTask: asTask))
    }
}

nonisolated final class FakePlumeAppClient: PlumeAppClient {
    enum Request: Equatable {
        case tab(directory: String, caller: PlumeCaller)
        case task(worktreePath: String, caller: PlumeCaller)
    }

    var tabResult: Bool
    var taskResult: Bool
    private(set) var requests: [Request] = []

    init(tabResult: Bool = true, taskResult: Bool = true) {
        self.tabResult = tabResult
        self.taskResult = taskResult
    }

    func openTab(directory: String, caller: PlumeCaller) -> Bool {
        requests.append(.tab(directory: directory, caller: caller))
        return tabResult
    }

    func openTask(worktreePath: String, caller: PlumeCaller) -> Bool {
        requests.append(.task(worktreePath: worktreePath, caller: caller))
        return taskResult
    }
}

// MARK: PR fetch

/// A fetch whose `wait` answers from a script, so the two-frame print runs
/// without threads or sleeps.
nonisolated final class ScriptedFetchCompletion: PRFetchCompletion, @unchecked Sendable {
    private var results: [Bool]
    private(set) var waits: [TimeInterval] = []
    let result: PullRequestMap?

    init(_ results: Bool..., result: PullRequestMap?) {
        self.results = results
        self.result = result
    }

    func wait(timeout: TimeInterval) -> Bool {
        waits.append(timeout)
        return results.isEmpty ? false : results.removeFirst()
    }
}

/// A list appended to from several threads.
nonisolated final class LockedList<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }

    var values: [Element] {
        lock.withLock { elements }
    }
}

// MARK: Context

/// The slice of `WorktreeContext` that `wt list`, `current` and the naming
/// helpers use, answered from a fixed list of worktrees. Paths default under
/// `newWorktreesDirectory`, or `root` for the main worktree.
nonisolated final class FakeWTContext: WTContext {
    struct Worktree {
        var row: WorktreeRow
        var path: String?
    }

    let git: any WorktreeGit
    let fakeGit: FakeWorktreeGit
    var layout: WorktreeLayout
    var root: String
    var repoDir: String
    var newWorktreesDirectory: String
    var mainName: String
    var settings = ProjectSettings()
    var nerdFontMode = NerdFontMode.automatic
    var baseBranch: String
    var baseRef: String { "origin/\(baseBranch)" }
    var trunkBranches: Set<String> = []
    var protected: [String] = []
    var forgeKind: ForgeKind = .none
    let console: any CLIConsole
    let buffer: BufferConsole
    var ui: TerminalUI = .plain
    var tabs: any TabOpener { recordingTabs }
    let recordingTabs: RecordingTabOpener

    var worktrees: [Worktree]
    var prefix: String?
    var current: String?
    /// Wins over `current`, for a name more than one worktree has.
    var currentPath: String?
    var fetchSession: PRFetchSession?
    /// Runs at the start of every `worktreeStatus` call, on its thread.
    var onWorktreeStatus: (@Sendable (String) -> Void)?
    private(set) var ensuredWorktreesDirectory = false

    init(
        worktrees: [WorktreeRow] = [],
        paths: [String?]? = nil,
        layout: WorktreeLayout = .standard,
        root: String = "/repo",
        mainName: String = "repo",
        prefix: String? = "",
        branches: Set<String> = [],
        baseBranch: String = "",
        current: String? = nil,
        currentPath: String? = nil,
        branchByPath: [String: String] = [:],
        canOpenTabs: Bool = true
    ) {
        let paths = paths ?? Array(repeating: nil, count: worktrees.count)
        self.worktrees = zip(worktrees, paths).map { Worktree(row: $0, path: $1) }
        self.layout = layout
        self.root = root
        self.repoDir = root
        self.newWorktreesDirectory = "\(root)/.plume/worktrees"
        self.mainName = mainName
        self.prefix = prefix
        self.baseBranch = baseBranch
        self.current = current
        self.currentPath = currentPath
        fakeGit = FakeWorktreeGit(branches: branches, branchByPath: branchByPath)
        git = fakeGit
        buffer = BufferConsole()
        console = buffer
        recordingTabs = RecordingTabOpener(canOpenTabs: canOpenTabs)
    }

    private func defaultPath(_ name: String) -> String {
        layout == .standard && name == mainName ? root : "\(newWorktreesDirectory)/\(name)"
    }

    private func path(of worktree: Worktree) -> String {
        worktree.path ?? defaultPath(worktree.row.name)
    }

    func branchPrefixResolution() -> String? { prefix }
    func startPRFetch(allBranches: Bool) -> PRFetchSession? { fetchSession }
    func listWorktreeNames() -> [String] { worktrees.map(\.row.name) }
    func worktreePathsInListOrder() -> [String] { worktrees.map(path(of:)) }

    func worktreePath(_ name: String) throws -> String {
        let paths = worktrees.filter { $0.row.name == name }.map(path(of:))
        if paths.count > 1 { throw CLIFailure("FakeWTContext: ambiguous name \(name)") }
        return paths.first ?? defaultPath(name)
    }

    func worktreeStatus(_ path: String) -> WorktreeStatus {
        onWorktreeStatus?(path)
        guard let row = worktrees.first(where: { self.path(of: $0) == path })?.row else {
            Issue.record("FakeWTContext.worktreeStatus: unknown path \(path)")
            return WorktreeStatus(display: "?", ahead: "", dirty: false, hasUpstream: false)
        }
        return WorktreeStatus(
            display: row.branch, ahead: row.ahead, dirty: row.dirty,
            remoteAhead: row.remoteAhead, remoteBehind: row.remoteBehind, hasUpstream: row.hasUpstream
        )
    }

    func currentWorktreePath() throws -> String {
        guard let current = currentWorktree() else { throw CLIFailure("not inside a git worktree") }
        return current.path
    }

    func currentWorktreeName() throws -> String {
        guard let current = currentWorktree() else { throw CLIFailure("not inside a git worktree") }
        return current.name
    }

    func currentWorktree() -> (name: String, path: String)? {
        if let currentPath, let worktree = worktrees.first(where: { path(of: $0) == currentPath }) {
            return (worktree.row.name, currentPath)
        }
        guard let current, let path = try? worktreePath(current) else { return nil }
        return (current, path)
    }

    func worktreeExists(_ name: String) -> Bool { worktrees.contains { $0.row.name == name } }

    func describeExisting(_ name: String) -> String {
        worktrees.filter { $0.row.name == name }.map(path(of:)).sorted().joined(separator: ", ")
    }

    func ensureWorktreesDirectory() throws { ensuredWorktreesDirectory = true }
}

struct StaticSettingsSource: ProjectSettingsSource {
    var configuration = ProjectsConfiguration()
    func load() -> ProjectsConfiguration { configuration }
}

// MARK: Scratch repositories

/// A temporary directory with its symlinks resolved, since git reports
/// `/private/var/...` for a path under `/var`.
func makeScratchDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wt-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Runs git, failing the test on a non-zero exit. Returns trimmed stdout.
@discardableResult
func runGit(_ arguments: [String], in directory: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed in \(directory)")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A repository at `<parent>/<name>` on `main` with one commit, and an
/// `origin` it has pushed `main` to. Signing is off: a signing agent is
/// unreachable from the test host.
func makeScratchRepository(in parent: String, name: String = "repo") throws -> String {
    let repo = "\(parent)/\(name)"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try runGit(["init", "-q", "-b", "main"], in: repo)
    try runGit(["config", "user.email", "test@example.com"], in: repo)
    try runGit(["config", "user.name", "Test"], in: repo)
    try runGit(["config", "commit.gpgsign", "false"], in: repo)
    try "hello\n".write(toFile: "\(repo)/README", atomically: true, encoding: .utf8)
    try runGit(["add", "README"], in: repo)
    try runGit(["commit", "-q", "-m", "Initial"], in: repo)
    let origin = "\(parent)/\(name)-origin.git"
    try runGit(["clone", "-q", "--bare", repo, origin], in: parent)
    try runGit(["remote", "add", "origin", origin], in: repo)
    try runGit(["fetch", "-q", "origin"], in: repo)
    return repo
}
