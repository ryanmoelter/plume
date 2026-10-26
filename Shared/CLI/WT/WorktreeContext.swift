import Foundation

nonisolated enum WorktreeLayout: String, Codable, Sendable, Equatable {
    /// The root holds a `.bare` repository; worktrees are its direct children
    /// and there is no main worktree.
    case bare
    /// The root is the main worktree; new worktrees go under
    /// `<root>/.plume/worktrees`.
    case standard
}

/// One worktree's local state, as `wt list` shows it.
nonisolated struct WorktreeStatus: Equatable, Sendable {
    /// The branch, `<short sha> (detached)`, or `?`.
    var display: String
    /// Commits ahead of the base ref, as a string; empty when unanswerable.
    var ahead: String
    var dirty: Bool
    var remoteAhead: Int
    var remoteBehind: Int
    var hasUpstream: Bool

    init(display: String, ahead: String, dirty: Bool, remoteAhead: Int = 0, remoteBehind: Int = 0, hasUpstream: Bool) {
        self.display = display
        self.ahead = ahead
        self.dirty = dirty
        self.remoteAhead = remoteAhead
        self.remoteBehind = remoteBehind
        self.hasUpstream = hasUpstream
    }
}

/// The layout and resolved settings every command runs against. The seam
/// tests substitute: `WorktreeContext` is the real one.
///
/// Worktrees are discovered from git's own registry, so one checked out
/// anywhere on disk is recognized. `newWorktreesDirectory` only decides where
/// `wt` puts the ones it creates.
nonisolated protocol WTContext: AnyObject {
    var git: any WorktreeGit { get }
    var layout: WorktreeLayout { get }
    var root: String { get }
    var repoDir: String { get }
    var newWorktreesDirectory: String { get }
    /// The main worktree's name; empty in the bare layout.
    var mainName: String { get }
    /// The project's settings over the defaults row, before derived
    /// fallbacks.
    var settings: ProjectSettings { get }
    var baseBranch: String { get }
    /// `origin/<baseBranch>`.
    var baseRef: String { get }
    /// Branches that never show a PR: the base branch and origin's default.
    var trunkBranches: Set<String> { get }
    /// Configured names plus `.bare` or the main worktree, always.
    var protected: [String] { get }
    var forgeKind: ForgeKind { get }
    var console: any CLIConsole { get }
    var ui: TerminalUI { get }
    var tabs: any TabOpener { get }

    /// The branch prefix, or nil when nothing is configured and `user.email`
    /// can't supply one. Resolved once, lazily: a missing email mustn't
    /// break commands that never create a branch.
    func branchPrefixResolution() -> String?
    /// Starts the PR fetch for the checked-out branches, or every local
    /// branch with `allBranches`. Nil when there is no forge, no forge CLI
    /// or nothing to fetch.
    func startPRFetch(allBranches: Bool) -> PRFetchSession?

    /// Every worktree's name, in display order: the main worktree first in
    /// the standard layout, then by name and path. A shared name appears once
    /// per worktree.
    func listWorktreeNames() -> [String]
    /// Paths parallel to `listWorktreeNames()`.
    func worktreePathsInListOrder() -> [String]
    /// Fails when no worktree has the name, or when several do.
    func worktreePath(_ name: String) throws -> String
    func worktreeStatus(_ path: String) -> WorktreeStatus
    /// Fails outside a registered worktree.
    func currentWorktreePath() throws -> String
    func currentWorktreeName() throws -> String
    /// The working directory's worktree, or nil outside one. The path comes
    /// from git, so this answers inside a worktree whose name is shared.
    func currentWorktree() -> (name: String, path: String)?
    func worktreeExists(_ name: String) -> Bool
    /// Where the worktrees with `name` are, comma-separated.
    func describeExisting(_ name: String) -> String
    /// Standard layout: creates `newWorktreesDirectory`, with `.plume`
    /// self-ignored by a `*` `.gitignore`. Bare layout: nothing.
    func ensureWorktreesDirectory() throws
}

nonisolated extension WTContext {
    func currentWorktreeNameOrNone() -> String? {
        currentWorktree()?.name
    }
}

nonisolated final class WorktreeContext: WTContext {
    let git: any WorktreeGit
    let layout: WorktreeLayout
    let root: String
    let repoDir: String
    let newWorktreesDirectory: String
    let mainName: String
    let settings: ProjectSettings
    let baseBranch: String
    let baseRef: String
    let trunkBranches: Set<String>
    let protected: [String]
    let console: any CLIConsole
    let ui: TerminalUI
    let tabs: any TabOpener

    init(
        git: any WorktreeGit,
        layout: WorktreeLayout,
        root: String,
        repoDir: String,
        newWorktreesDirectory: String,
        mainName: String,
        settings: ProjectSettings = ProjectSettings(),
        console: any CLIConsole = BufferConsole(),
        ui: TerminalUI = .plain,
        tabs: (any TabOpener)? = nil
    ) {
        self.git = git
        self.layout = layout
        self.root = root
        self.repoDir = repoDir
        self.newWorktreesDirectory = newWorktreesDirectory
        self.mainName = mainName
        self.settings = settings
        self.console = console
        self.ui = ui
        self.tabs = tabs ?? PlumeTabOpener(client: SocketPlumeAppClient(socketPath: ""), environment: [:], console: console)

        let originHead = git.originHead()
        baseBranch = WTSettings.baseBranch(configured: settings.baseBranch, originHead: originHead)
        baseRef = "origin/\(baseBranch)"
        trunkBranches = WTSettings.trunkBranches(baseBranch: baseBranch, originHead: originHead)
        protected = WTSettings.protectedWorktrees(configured: settings.protectedWorktrees, layout: layout, mainName: mainName)
    }

    /// Finds the repository from the working directory and loads its project
    /// settings. Fails outside a git repository.
    static func detect(
        git: any WorktreeGit,
        settingsSource: any ProjectSettingsSource,
        console: any CLIConsole,
        environment: [String: String]
    ) throws -> WorktreeContext {
        // TODO(PLUME-316 group B)
        throw CLIFailure("not inside a git repo")
    }

    var forgeKind: ForgeKind {
        // TODO(PLUME-316 group B)
        .none
    }

    func branchPrefixResolution() -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    func startPRFetch(allBranches: Bool) -> PRFetchSession? {
        // TODO(PLUME-316 group C)
        nil
    }

    func listWorktreeNames() -> [String] {
        // TODO(PLUME-316 group B)
        []
    }

    func worktreePathsInListOrder() -> [String] {
        // TODO(PLUME-316 group B)
        []
    }

    func worktreePath(_ name: String) throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func worktreeStatus(_ path: String) -> WorktreeStatus {
        // TODO(PLUME-316 group B)
        WorktreeStatus(display: "", ahead: "", dirty: false, hasUpstream: false)
    }

    func currentWorktreePath() throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func currentWorktreeName() throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func currentWorktree() -> (name: String, path: String)? {
        // TODO(PLUME-316 group B)
        nil
    }

    func worktreeExists(_ name: String) -> Bool {
        // TODO(PLUME-316 group B)
        false
    }

    func describeExisting(_ name: String) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    func ensureWorktreesDirectory() throws {
        // TODO(PLUME-316 group B)
    }
}
