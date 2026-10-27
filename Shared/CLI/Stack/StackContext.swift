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
        self.app = app ?? SocketPlumeAppClient(socketPath: "")
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
        throw CLIFailure("not implemented")
    }

    /// `stack: <message>` on stderr, unless quiet.
    func warn(_ message: String) {}
}
