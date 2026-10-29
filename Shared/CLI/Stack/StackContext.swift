import Foundation

/// The repository, resolved settings and output every `stack` command runs
/// against.
nonisolated final class StackContext {
    let git: any StackGit
    let console: any CLIConsole
    let ui: TerminalUI
    /// The base branch: configured, else origin's default, else `main`.
    let trunk: String
    /// Prepended to the names `create` and `split` make; empty for none.
    let branchPrefix: String
    let state: StackStateStore
    /// Nil when origin is on no forge `stack` knows.
    let forge: (any StackForge)?
    let forgeKind: ForgeKind
    let nerdFontMode: NerdFontMode
    let app: any PlumeAppClient
    /// The `fzf` to pick with, or nil for a numbered prompt.
    let fzfPath: String?
    /// Silences warnings, for completion.
    var quiet = false

    init(
        git: any StackGit,
        console: any CLIConsole = BufferConsole(),
        ui: TerminalUI = .plain,
        trunk: String = "main",
        branchPrefix: String = "",
        stateDirectory: String,
        forge: (any StackForge)? = nil,
        forgeKind: ForgeKind? = nil,
        nerdFontMode: NerdFontMode = .automatic,
        app: (any PlumeAppClient)? = nil,
        fzfPath: String? = nil
    ) {
        self.git = git
        self.console = console
        self.ui = ui
        self.trunk = trunk
        self.branchPrefix = branchPrefix
        self.state = StackStateStore(directory: stateDirectory)
        self.forge = forge
        self.forgeKind = forgeKind ?? forge?.kind ?? .none
        self.nerdFontMode = nerdFontMode
        self.app = app ?? SocketPlumeAppClient(socketPath: nil)
        self.fzfPath = fzfPath
    }

    /// Finds the repository from `workingDirectory` and resolves its
    /// settings. Fails outside a git repository.
    static func detect(
        workingDirectory: String?,
        settingsSource: any ProjectSettingsSource,
        console: any CLIConsole,
        environment: [String: String]
    ) throws -> StackContext {
        let (root, commonDir) = try WorktreeContext.locate(git: ProcessWorktreeGit(workingDirectory: workingDirectory))
        let git = ProcessStackGit(workingDirectory: workingDirectory)
        let settings = settingsSource.load().settings(forRepository: root)
        let nerdFontMode = settingsSource.nerdFontMode()
        let stateDirectory = "\(commonDir)/stack"
        let originURL = git.originURL()
        let kind = ForgeKind.resolving(originURL: originURL, override: settings.forge)
        let forge: (any StackForge)?
        switch kind {
        case .github:
            forge = GitHubStackForge(workingDirectory: workingDirectory, stateDirectory: stateDirectory)
        case .gitlab:
            forge = GitLabQuery.fullPath(originURL: originURL).map {
                GitLabStackForge(fullPath: $0, workingDirectory: workingDirectory)
            }
        case .none:
            forge = nil
        }
        return StackContext(
            git: git,
            console: console,
            ui: WTSettings.terminalUI(
                settings: settings,
                nerdFont: nerdFontMode,
                stdoutIsTerminal: console.stdoutIsTerminal,
                environment: environment
            ),
            trunk: WTSettings.baseBranch(configured: settings.baseBranch, originHead: git.originHead()),
            branchPrefix: settings.branchPrefix.map(WTSettings.normalizedBranchPrefix) ?? "",
            stateDirectory: stateDirectory,
            forge: forge,
            forgeKind: kind,
            nerdFontMode: nerdFontMode,
            app: SocketPlumeAppClient(socketPath: CLISocket.resolvedPath(environment: environment)),
            fzfPath: CLIProcess.which("fzf", environment: environment)
        )
    }

    /// `stack: <message>` on stderr, unless quiet.
    func warn(_ message: String) {
        if !quiet { console.printError("\(Stack.programName): \(message)") }
    }

    /// The state as loaded, without writing back a prune.
    func loadState() throws -> StackBranches {
        try state.load(localBranches: Set(try git.localBranches()), warn: warn).branches
    }

    /// Loads the state and writes back anything the load repaired. The
    /// caller holds the lock.
    func loadAndFlushLocked() throws -> StackBranches {
        let result = try state.load(localBranches: Set(try git.localBranches()), warn: warn)
        if result.dirty { try saveState(result.branches) }
        return result.branches
    }

    func loadAndFlush() throws -> StackBranches {
        try state.withLock { try loadAndFlushLocked() }
    }

    func saveState(_ branches: StackBranches) throws {
        try state.save(branches, warn: warn)
    }

    /// Prepends the branch prefix to a new branch name that lacks it.
    func applyPrefix(_ name: String) -> String {
        !branchPrefix.isEmpty && !name.hasPrefix(branchPrefix) ? branchPrefix + name : name
    }

    /// Fails with the setup hint when origin is on no forge `stack` knows,
    /// and with the cause when its CLI is missing or signed out.
    func requireForge() throws -> any StackForge {
        guard let forge else {
            throw CLIFailure("no GitHub or GitLab remote detected — set the forge for this repository in Plume's Settings ▸ Projects")
        }
        try forge.requireReady()
        return forge
    }
}
