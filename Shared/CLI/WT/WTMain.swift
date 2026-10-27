import Foundation

nonisolated extension WT {
    static let helpCommands: Set<String> = ["-h", "--help", "help"]

    /// `plume wt …`, and `wt …` through the opt-in link. Handles the
    /// commands that need no repository, builds the context, runs the
    /// subcommand, and turns a `CLIFailure` into `wt: <message>` on stderr.
    /// Returns the exit status.
    static func main(
        _ arguments: [String],
        environment: [String: String],
        console: any CLIConsole,
        version: String?,
        git: any WorktreeGit = ProcessWorktreeGit()
    ) -> Int32 {
        if let first = arguments.first, ["--version", "-V", "version"].contains(first) {
            console.print("\(programName) \(version ?? "(not inside Plume.app)")")
            return CLIExitCode.success
        }

        do {
            // Runs at shell startup from any directory, so it answers before
            // the repository is looked up.
            if arguments.first == "init" {
                throw CLIFailure(#"shell integration moved to plume: eval "$(plume init zsh)""#)
            }
            let settingsSource = UserDefaultsProjectSettingsSource(environment: environment)
            let ctx: WorktreeContext
            do {
                ctx = try WorktreeContext.detect(
                    git: git,
                    settingsSource: settingsSource,
                    console: console,
                    environment: environment
                )
            } catch is CLIFailure where arguments.isEmpty || helpCommands.contains(arguments[0]) {
                let ui = WTSettings.terminalUI(
                    settings: settingsSource.load().defaults,
                    stdoutIsTerminal: console.stdoutIsTerminal,
                    environment: environment
                )
                usage(console: console, ui: ui)
                if arguments.isEmpty { throw CLIFailure(nil) }
                return CLIExitCode.success
            } catch is CLIFailure where arguments.first == "__complete" {
                // Completion runs on every Tab press, in any directory.
                return CLIExitCode.success
            } catch let failure as CLIFailure where arguments.first == "current" {
                if currentOutsideRepository(Array(arguments.dropFirst()), console: console) { return CLIExitCode.success }
                throw failure
            }
            try run(ctx, arguments)
            return CLIExitCode.success
        } catch let failure as CLIFailure {
            if let message = failure.message { console.printError("\(programName): \(message)") }
            return failure.code
        } catch {
            console.printError("\(programName): \(error.localizedDescription)")
            return CLIExitCode.failure
        }
    }

    /// Dispatches one subcommand, with its aliases, against `ctx`. An empty
    /// command prints the help and fails; an unknown one fails naming it.
    static func run(_ ctx: any WTContext, _ arguments: [String]) throws {
        let command = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        switch command {
        case "checkout", "co": try checkout(ctx, rest)
        case "cob": try checkout(ctx, rest, create: true)
        case "open", "o": try open(ctx, rest)
        case "background", "bg": try background(ctx, rest)
        case "list", "l": try list(ctx, rest)
        case "delete", "d": try delete(ctx, rest)
        case "prune", "p": try prune(ctx, rest)
        case "rename", "r": try rename(ctx, rest)
        case "commit", "cm": try commit(ctx, rest)
        case "switch", "s": try switchTo(ctx, rest)
        case "path": try path(ctx, rest)
        case "current": try current(ctx, rest)
        case "foreground", "fg": try foreground(ctx, rest)
        case "setup": try setup(ctx, rest)
        case "__complete": try complete(ctx, rest)
        case _ where helpCommands.contains(command): usage(ctx)
        case "":
            usage(ctx)
            throw CLIFailure(nil)
        default:
            throw CLIFailure("unknown subcommand: \(command) (try -h)")
        }
    }
}
