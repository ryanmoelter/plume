import Foundation

nonisolated extension WT {
    /// `plume wt …`, and `wt …` through the opt-in link. Handles the
    /// commands that need no repository, builds the context, runs the
    /// subcommand, and turns a `CLIFailure` into `wt: <message>` on stderr.
    /// Returns the exit status.
    static func main(
        _ arguments: [String],
        environment: [String: String],
        console: any CLIConsole,
        version: String?
    ) -> Int32 {
        // TODO(PLUME-316 group B)
        CLIExitCode.failure
    }

    /// Dispatches one subcommand, with its aliases, against `ctx`. An empty
    /// command prints the help and fails; an unknown one fails naming it.
    static func run(_ ctx: any WTContext, _ arguments: [String]) throws {
        // TODO(PLUME-316 group B)
    }
}
