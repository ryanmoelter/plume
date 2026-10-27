import Darwin
import Foundation
import Testing
@testable import Plume

// MARK: In-memory git

/// A commit graph in memory: each commit maps to its ancestors, newest
/// first, itself excluded. Branches are named pointers into it, the trunk
/// among them, which answers every graph question `list` asks without a
/// repository.
nonisolated final class FakeStackGit: StackGit {
    var tips: [String: String]
    var ancestors: [String: [String]]
    var origin: [String: (ahead: Int, behind: Int)]
    /// The branches that exist as local refs. Defaults to every tip.
    var branches: Set<String>
    var current: String?

    init(
        tips: [String: String],
        ancestors: [String: [String]],
        origin: [String: (ahead: Int, behind: Int)] = [:],
        branches: Set<String>? = nil,
        current: String? = nil
    ) {
        self.tips = tips
        self.ancestors = ancestors
        self.origin = origin
        self.branches = branches ?? Set(tips.keys)
        self.current = current
    }

    var workingDirectory: String? { nil }

    func resolve(_ ref: String) -> String? {
        if ref.hasPrefix("refs/remotes/") { return nil }
        if ref.hasPrefix("refs/heads/") {
            let name = String(ref.dropFirst("refs/heads/".count))
            return branches.contains(name) ? tips[name] : nil
        }
        if let tip = tips[ref] { return tip }
        return ancestors[ref] != nil ? ref : nil
    }

    private func reachable(_ commit: String) -> Set<String> {
        Set([commit] + (ancestors[commit] ?? []))
    }

    func currentBranch() -> String? { current }
    func localBranches() -> [String] { branches.sorted() }
    func branchExists(_ branch: String) -> Bool { branches.contains(branch) }

    func isAncestor(_ ancestor: String, _ descendant: String) -> Bool {
        guard let a = resolve(ancestor), let d = resolve(descendant) else { return false }
        return reachable(d).contains(a)
    }

    func mergeBase(_ lhs: String, _ rhs: String) -> String? {
        guard let l = resolve(lhs), let r = resolve(rhs) else { return nil }
        let common = reachable(l).intersection(reachable(r))
        return common.max { reachable($0).count < reachable($1).count }
    }

    func revListCount(_ range: String) throws -> Int {
        let parts = range.components(separatedBy: "..")
        guard parts.count == 2, let lo = resolve(parts[0]), let hi = resolve(parts[1]) else {
            throw CLIFailure("FakeStackGit: bad range \(range)")
        }
        return reachable(hi).subtracting(reachable(lo)).count
    }

    func originAheadBehind(_ branch: String) -> (ahead: Int, behind: Int)? { origin[branch] }
    func worktreeMap() -> [String: String] { [:] }
    func originURL() -> String? { nil }

    func run(_ arguments: [String], capture: Bool, input: String?) throws -> CLIProcessResult {
        throw CLIFailure("FakeStackGit.run: \(arguments.joined(separator: " "))")
    }
}

/// Ancestors for a linear history given oldest first: `a1` → `[m0]`,
/// `a2` → `[a1, m0]`.
func linearHistory(_ commits: String...) -> [String: [String]] {
    var ancestors: [String: [String]] = [:]
    for (index, commit) in commits.enumerated() {
        ancestors[commit] = Array(commits[..<index].reversed())
    }
    return ancestors
}

func entry(_ parent: String, _ base: String) -> StackEntry {
    StackEntry(parent: parent, base: base)
}

func stackContext(
    _ git: any StackGit,
    console: BufferConsole = BufferConsole(),
    ui: TerminalUI = .plain,
    trunk: String = "main",
    branchPrefix: String = "",
    stateDirectory: String = "/nonexistent-stack-state",
    forge: (any StackForge)? = nil
) -> StackContext {
    StackContext(
        git: git,
        console: console,
        ui: ui,
        trunk: trunk,
        branchPrefix: branchPrefix,
        stateDirectory: stateDirectory,
        forge: forge
    )
}

func stackPR(
    _ number: Int,
    state: PullRequestState = .open,
    isDraft: Bool = false,
    base: String? = "main",
    headRefOid: String? = nil,
    reviewDecision: ReviewDecision = .none,
    checks: [CheckContext] = [],
    githubStack: GitHubStackMembership? = nil
) -> PullRequest {
    PullRequest(
        number: number,
        state: state,
        isDraft: isDraft,
        url: "u",
        title: "t",
        baseRefName: base,
        headRefOid: headRefOid,
        reviewDecision: reviewDecision,
        checkContexts: checks,
        githubStack: githubStack
    )
}

let nerdUI = TerminalUI(glyphSet: .nerd)

// MARK: Forge fakes

/// A pull request map plus a record of every mutation `submit` and `sync`
/// attempt.
nonisolated final class RecordingStackForge: StackForge, @unchecked Sendable {
    var prs: PullRequestMap
    var fetchFails = false
    private(set) var edits: [(number: Int, base: String)] = []
    private(set) var created: [(head: String, base: String, title: String, draft: Bool)] = []
    var stacks: FakeNativeStacks?

    init(_ prs: PullRequestMap = [:], kind: ForgeKind = .github) {
        self.prs = prs
        self.kind = kind
    }

    let kind: ForgeKind
    var numberPrefix: String { kind == .gitlab ? "!" : "#" }
    var noun: String { kind == .gitlab ? "MR" : "PR" }
    var cliName: String { kind == .gitlab ? "glab" : "gh" }
    var isInstalled: Bool { true }
    func requireReady() throws {}

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        if fetchFails { return nil }
        return prs.filter { branches.contains($0.key) }
    }

    func editBase(number: Int, base: String) throws -> CLIProcessResult {
        edits.append((number, base))
        return CLIProcessResult(status: 0, stdout: "", stderr: "")
    }

    func create(head: String, base: String, title: String, body: String, draft: Bool) throws -> CLIProcessResult {
        created.append((head, base, title, draft))
        return CLIProcessResult(status: 0, stdout: "https://example.com/pr/\(created.count)\n", stderr: "")
    }

    var nativeStacks: (any GitHubNativeStacks)? { stacks }
}

/// Records the native-stack mutations `syncGitHubStack` attempts.
nonisolated final class FakeNativeStacks: GitHubNativeStacks {
    var existing: GitHubNativeStack?
    var createSucceeds: Bool
    var addSucceeds: Bool
    var enabled = true
    private(set) var created: [[Int]] = []
    private(set) var added: [(stack: Int, pullRequests: [Int])] = []
    private(set) var markedUnavailable = false

    init(existing: GitHubNativeStack? = nil, createSucceeds: Bool = true, addSucceeds: Bool = true) {
        self.existing = existing
        self.createSucceeds = createSucceeds
        self.addSucceeds = addSucceeds
    }

    func isEnabled() -> Bool { enabled }
    func markUnavailable() { markedUnavailable = true }
    func stack(containing pullRequest: Int) -> GitHubNativeStack? { existing }

    func create(_ pullRequests: [Int]) -> (ok: Bool, number: Int?) {
        created.append(pullRequests)
        return (createSucceeds, createSucceeds ? 77 : nil)
    }

    func add(_ pullRequests: [Int], to stack: Int) -> Bool {
        added.append((stack, pullRequests))
        return addSucceeds
    }
}

// MARK: Real repositories

/// A bare `origin` plus a work clone on `main` with one empty commit, for
/// the tests that need git's own rebase arithmetic. Signing is off: a
/// signing agent is unreachable from the test host.
nonisolated final class StackScratchRepo {
    let directory: String
    let origin: String
    let work: String

    init() throws {
        directory = try makeScratchDirectory()
        origin = "\(directory)/origin.git"
        work = "\(directory)/work"
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try git("init", "-q", "--bare", "-b", "main", in: origin)
        try git("init", "-q", "-b", "main")
        for (key, value) in [
            ("user.email", "t@test"), ("user.name", "t"),
            ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
        ] {
            try git("config", key, value)
        }
        try git("remote", "add", "origin", origin)
        try git("commit", "-q", "--allow-empty", "-m", "root")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: directory)
    }

    var stateDirectory: String { "\(work)/.git/stack" }

    /// Trimmed stdout; throws on a non-zero exit.
    @discardableResult
    func git(_ arguments: String..., in directory: String? = nil) throws -> String {
        let result = try gitResult(arguments, in: directory)
        guard result.status == 0 else {
            throw CLIFailure("git \(arguments.joined(separator: " ")) failed: \(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For the git commands a test expects may fail, such as a conflicting
    /// merge.
    @discardableResult
    func gitAllowingFailure(_ arguments: String..., in directory: String? = nil) throws -> CLIProcessResult {
        try gitResult(arguments, in: directory)
    }

    private func gitResult(_ arguments: [String], in directory: String?) throws -> CLIProcessResult {
        try CLIProcess.run(["git"] + arguments, check: false, workingDirectory: directory ?? work)
    }

    /// Writes a file named `name` holding its own name and commits it.
    /// Returns the new sha.
    @discardableResult
    func commit(_ name: String, in directory: String? = nil) throws -> String {
        let directory = directory ?? work
        try write(name, name, in: directory)
        try git("add", name, in: directory)
        try git("commit", "-q", "-m", name, in: directory)
        return try git("rev-parse", "HEAD", in: directory)
    }

    func write(_ name: String, _ contents: String, in directory: String? = nil) throws {
        try contents.write(toFile: "\(directory ?? work)/\(name)", atomically: true, encoding: .utf8)
    }

    func read(_ name: String) throws -> String {
        try String(contentsOfFile: "\(work)/\(name)", encoding: .utf8)
    }

    func subjects(_ rev: String, in directory: String? = nil) throws -> [String] {
        let out = try git("log", "--format=%s", rev, in: directory)
        return out.isEmpty ? [] : out.components(separatedBy: "\n")
    }

    func rev(_ ref: String) throws -> String {
        try git("rev-parse", ref)
    }

    func isAncestor(_ ancestor: String, _ descendant: String) throws -> Bool {
        try gitAllowingFailure("merge-base", "--is-ancestor", ancestor, descendant).status == 0
    }

    func localBranches() throws -> [String] {
        try git("branch", "--format=%(refname:short)").components(separatedBy: "\n")
    }

    func pushTrunk() throws {
        try git("push", "-q", "-f", "origin", "main")
    }

    func context(forge: (any StackForge)? = nil, console: BufferConsole = BufferConsole()) -> StackContext {
        StackContext(
            git: ProcessStackGit(workingDirectory: work),
            console: console,
            trunk: "main",
            stateDirectory: stateDirectory,
            forge: forge
        )
    }

    func writeState(_ branches: StackBranches) throws {
        try StackStateStore(directory: stateDirectory).save(branches) { _ in }
    }

    func loadState() throws -> StackBranches {
        try StackStateStore(directory: stateDirectory)
            .load(localBranches: Set(localBranches())) { _ in }
            .branches
    }
}

/// The failure `body` throws, or nil when it returns.
func stackFailure(_ body: () throws -> Void) -> CLIFailure? {
    do {
        try body()
        return nil
    } catch let failure as CLIFailure {
        return failure
    } catch {
        return CLIFailure("unexpected error: \(error)")
    }
}
