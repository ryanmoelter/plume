import Foundation

/// `plume stack`: stacked branches for a squash-merge PR/MR workflow.
nonisolated enum Stack {
    static let programName = "stack"
    /// A restack stopped on a rebase conflict.
    static let conflictExitCode: Int32 = 3
    /// The listing paints at once and never waits on the forge, so its fetch
    /// gets a budget well past what a blocking wait could afford.
    static let listPRBudget: TimeInterval = 8
    /// A mutating command has committed to the forge, so it waits rather
    /// than degrade to a partial answer.
    static let blockingPRBudget: TimeInterval = 30

    static let commands = [
        "list", "l", "la", "create", "c", "split", "track", "untrack",
        "checkout", "co", "prev", "next", "first", "last",
        "restack", "submit", "sync", "setup", "help",
    ]

    /// `plume stack …`, and `stack …` through the opt-in link. Returns the
    /// exit status.
    static func main(
        _ arguments: [String],
        environment: [String: String],
        console: any CLIConsole,
        version: String?,
        workingDirectory: String? = nil
    ) -> Int32 {
        console.printError("\(programName): not implemented")
        return CLIExitCode.failure
    }

    static func run(_ ctx: StackContext, _ arguments: [String]) throws {
        throw CLIFailure("not implemented")
    }
}

/// The ahead/behind counts against origin, shared by both frames of a live
/// listing: they are local, so they can't change between them.
nonisolated final class AheadBehindCache {
    var values: [String: (ahead: Int, behind: Int)?] = [:]

    init() {}
}

nonisolated enum StackNavigation: String, Sendable {
    case prev
    case next
    case first
    case last
}

nonisolated extension Stack {
    static func list(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }

    /// The git-log-style graph, without a trailing newline. The far-left
    /// column is the trunk; each root attaches at its fork point, nearest
    /// first. `prState` decides the PR column.
    static func render(
        _ ctx: StackContext,
        _ branches: StackBranches,
        roots: [String],
        current: String?,
        prs: PullRequestMap,
        prState: PRState,
        forgeIcon: String? = nil,
        numberPrefix: String = "#",
        aheadBehind: AheadBehindCache? = nil
    ) throws -> String {
        throw CLIFailure("not implemented")
    }

    /// Prints the graph, filling in the PR column as `fetch` lands. `live`
    /// paints at once and redraws in place; otherwise it waits and prints
    /// once, so a piped reader never sees a stale frame.
    static func printLive(
        _ ctx: StackContext,
        _ branches: StackBranches,
        roots: [String],
        current: String?,
        fetch: (any PRFetchCompletion)?,
        forgeIcon: String,
        numberPrefix: String,
        live: Bool
    ) throws {
        throw CLIFailure("not implemented")
    }

    /// The fetch's pull requests, or none when it failed or timed out, so a
    /// half-done submit reads "no PR here" rather than stopping.
    static func collectPRs(_ fetch: any PRFetchCompletion) -> PullRequestMap { [:] }

    static func create(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func split(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func track(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func untrack(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func checkout(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func navigate(_ ctx: StackContext, _ which: StackNavigation, _ arguments: [String]) throws {
        throw CLIFailure("not implemented")
    }
    static func restack(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func submit(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func sync(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func setup(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }
    static func complete(_ ctx: StackContext, _ arguments: [String]) throws { throw CLIFailure("not implemented") }

    /// Retargets an open PR whose base isn't `parent`.
    static func retargetPR(
        _ ctx: StackContext,
        _ forge: any StackForge,
        branch: String,
        pr: PullRequest,
        parent: String,
        dryRun: Bool
    ) throws {
        throw CLIFailure("not implemented")
    }

    /// Registers or extends the GitHub stack for a just-submitted chain.
    /// Best effort: warns and returns on any failure.
    static func syncGitHubStack(
        _ ctx: StackContext,
        _ stacks: any GitHubNativeStacks,
        order: [String],
        prs: PullRequestMap,
        dryRun: Bool
    ) {}
}
