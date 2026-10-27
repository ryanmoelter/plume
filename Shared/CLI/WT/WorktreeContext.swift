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
        let (layoutRoot, common) = try locate(git: git)
        let layout: WorktreeLayout = (common as NSString).lastPathComponent == ".bare" ? .bare : .standard
        // A standard repository's common dir is `<main worktree>/.git`, so its
        // parent is the main worktree from any linked worktree.
        let repoDir = layout == .bare ? common : layoutRoot
        git.repoDir = repoDir

        let settings = settingsSource.load().settings(forRepository: layoutRoot)
        let tabs = PlumeTabOpener(
            client: SocketPlumeAppClient(socketPath: CLISocket.resolvedPath(environment: environment)),
            environment: environment,
            console: console
        )
        return WorktreeContext(
            git: git,
            layout: layout,
            root: layoutRoot,
            repoDir: repoDir,
            newWorktreesDirectory: layout == .bare ? layoutRoot : "\(layoutRoot)/.plume/worktrees",
            mainName: layout == .bare ? "" : (layoutRoot as NSString).lastPathComponent,
            settings: settings,
            console: console,
            ui: WTSettings.terminalUI(settings: settings, stdoutIsTerminal: console.stdoutIsTerminal, environment: environment),
            tabs: tabs
        )
    }

    /// The repository's root, which keys its project settings, and git's
    /// common dir, from the working directory. Settings ▸ Projects keys its
    /// writes the same way.
    static func locate(git: any WorktreeGit) throws -> (root: String, commonDir: String) {
        guard let top = git.toplevel() else { throw CLIFailure("not inside a git repo") }
        guard var common = git.commonDir(root: top) else { throw CLIFailure("failed to resolve git common dir") }
        // `--git-common-dir` can be relative to the directory it ran in.
        if !common.hasPrefix("/") { common = lexicallyNormalized("\(top)/\(common)") }
        return ((common as NSString).deletingLastPathComponent, common)
    }

    /// Collapses `.` and `..` without touching the file system, which would
    /// resolve symlinks such as `/var` → `/private/var`.
    private static func lexicallyNormalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    var forgeKind: ForgeKind {
        ForgeKind.resolving(originURL: git.originURL(), override: settings.forge)
    }

    /// Resolved on first use, so a missing `user.email` only fails commands
    /// that create a branch. The outer optional means "not yet resolved".
    private var prefixResolution: String??

    func branchPrefixResolution() -> String? {
        if let prefixResolution { return prefixResolution }
        let resolved = WTSettings.branchPrefix(configured: settings.branchPrefix, userEmail: git.configGet("user.email"))
        prefixResolution = .some(resolved)
        return resolved
    }

    func startPRFetch(allBranches: Bool) -> PRFetchSession? {
        let kind = forgeKind
        guard let backend = ForgeBackends.backend(for: kind, originURL: git.originURL(), workingDirectory: repoDir),
              backend.isInstalled
        else { return nil }
        // Only the checked-out branches by default: a query over every branch
        // is slow enough on a big repository to time out.
        let branches = allBranches ? git.localBranches() : git.worktreeRecords().map(\.branch)
        if branches.isEmpty { return nil }
        return PRFetchSession(
            completion: PRFetch(branches: branches, fetch: { backend.pullRequests(forBranches: $0) }),
            numberPrefix: backend.numberPrefix,
            forgeIcon: ui.forgeIcon(for: kind)
        )
    }

    // MARK: Registry

    private var registryCache: [String: [String]]?

    /// Every registered worktree's paths by folder name. Names collect into
    /// lists because two worktrees in different directories can share one.
    private var registry: [String: [String]] {
        if let registryCache { return registryCache }
        var registry: [String: [String]] = [:]
        for entry in git.worktreeEntries() {
            let name: String
            if entry.path == root {
                // The bare layout's root is no worktree, so it has no name.
                name = mainName
            } else {
                name = (entry.path as NSString).lastPathComponent
                // Skips the bare layout's own `.bare`. Only linked worktrees
                // are filtered: a main worktree in `~/.dotfiles` keeps its name.
                if name.hasPrefix(".") { continue }
            }
            if name.isEmpty { continue }
            registry[name, default: []].append(entry.path)
        }
        registryCache = registry
        return registry
    }

    /// (name, path) in display order: the main worktree first in the
    /// standard layout, then by name and path.
    private var rows: [(name: String, path: String)] {
        let sorted = registry
            .flatMap { name, paths in paths.map { (name: name, path: $0) } }
            .sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        guard layout == .standard else { return sorted }
        return sorted.filter { $0.name == mainName } + sorted.filter { $0.name != mainName }
    }

    func listWorktreeNames() -> [String] {
        rows.map(\.name)
    }

    func worktreePathsInListOrder() -> [String] {
        rows.map(\.path)
    }

    func worktreePath(_ name: String) throws -> String {
        if name.isEmpty { throw CLIFailure("worktree name required") }
        guard let paths = registry[name], let first = paths.first else {
            throw CLIFailure("no worktree named \(name)")
        }
        if paths.count > 1 {
            let listed = paths.sorted().map { "    \($0)" }.joined(separator: "\n")
            throw CLIFailure("ambiguous name \(name) — \(paths.count) worktrees match:\n\(listed)")
        }
        return first
    }

    /// One `git status -b --porcelain=v2` gives the branch, the upstream
    /// delta and dirtiness. Ahead is measured against the base ref, not the
    /// upstream, so it needs its own call.
    func worktreeStatus(_ path: String) -> WorktreeStatus {
        var head: String?
        var dirty = false
        var remoteAhead = 0
        var remoteBehind = 0
        var hasUpstream = false
        for line in git.statusV2Lines(path) {
            if line.hasPrefix("# branch.head ") {
                head = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // `+A -B`, present only with an upstream.
                let counts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if counts.count == 2, let ahead = Int(counts[0]), let behind = Int(counts[1]) {
                    remoteAhead = ahead
                    remoteBehind = -behind
                    hasUpstream = true
                }
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        let display = switch head {
        case nil, "": "?"
        case "(detached)": "\(git.shortHead(path) ?? "?") (detached)"
        case let head?: head
        }
        return WorktreeStatus(
            display: display,
            ahead: git.aheadCount(path, baseRef: baseRef),
            dirty: dirty,
            remoteAhead: remoteAhead,
            remoteBehind: remoteBehind,
            hasUpstream: hasUpstream
        )
    }

    private var registeredPaths: Set<String> {
        Set(registry.values.joined())
    }

    func currentWorktreePath() throws -> String {
        guard let top = git.toplevel() else { throw CLIFailure("not inside a git worktree") }
        guard registeredPaths.contains(top) else { throw CLIFailure("cwd (\(top)) is not a worktree of \(root)") }
        return top
    }

    func currentWorktreeName() throws -> String {
        name(ofWorktreeAt: try currentWorktreePath())
    }

    func currentWorktree() -> (name: String, path: String)? {
        guard let top = git.toplevel(), registeredPaths.contains(top) else { return nil }
        return (name(ofWorktreeAt: top), top)
    }

    private func name(ofWorktreeAt path: String) -> String {
        layout == .standard && path == root ? mainName : (path as NSString).lastPathComponent
    }

    func worktreeExists(_ name: String) -> Bool {
        registry[name] != nil
    }

    func describeExisting(_ name: String) -> String {
        (registry[name] ?? []).sorted().joined(separator: ", ")
    }

    func ensureWorktreesDirectory() throws {
        guard layout == .standard else { return }
        let plumeDirectory = "\(root)/.plume"
        let gitignore = "\(plumeDirectory)/.gitignore"
        do {
            try FileManager.default.createDirectory(atPath: newWorktreesDirectory, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: gitignore, isDirectory: &isDirectory) {
                try "*\n".write(toFile: gitignore, atomically: true, encoding: .utf8)
            }
        } catch {
            throw CLIFailure("can't create \(newWorktreesDirectory): \(error.localizedDescription)")
        }
    }
}
