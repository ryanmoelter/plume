import Foundation

/// Pull requests by branch. A branch with no pull request is absent.
typealias PullRequestMap = [String: PullRequest]

/// What a listing's PR column knows. The raw values are the `pr_state` field
/// of `wt list --json`.
nonisolated enum PRState: String, Codable, Sendable, Equatable {
    /// The fetch landed: render per branch.
    case on
    /// The fetch is still in flight.
    case loading
    /// The fetch outlived its budget.
    case wait
    /// The fetch failed.
    case error
    /// No forge CLI, or no forge: the column is omitted.
    case off
}

/// A forge fetch running in the background, as a listing waits on it.
nonisolated protocol PRFetchCompletion: AnyObject, Sendable {
    /// Whether the fetch finished within `timeout` seconds.
    func wait(timeout: TimeInterval) -> Bool
    /// The pull requests once finished, or nil when the fetch failed.
    var result: PullRequestMap? { get }
}

/// Runs a fetch on a background thread, so a slow or hung forge can neither
/// block the listing nor outlive the process.
nonisolated final class PRFetch: PRFetchCompletion, @unchecked Sendable {
    private let done = DispatchGroup()
    private let lock = NSLock()
    private var finished: PullRequestMap?

    init(branches: [String], fetch: @escaping @Sendable ([String]) -> PullRequestMap?) {
        done.enter()
        // A plain thread rather than a queue, so a hung fetch never holds up
        // process exit.
        Thread { [self] in
            let prs = fetch(branches)
            lock.withLock { finished = prs }
            done.leave()
        }.start()
    }

    func wait(timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }

    var result: PullRequestMap? {
        lock.withLock { finished }
    }

    /// A finished fetch's result as a column state: `on` with the map, or
    /// `error` with an empty one when the fetch failed.
    static func resolve(_ result: PullRequestMap?) -> (state: PRState, prs: PullRequestMap) {
        result.map { (.on, $0) } ?? (.error, [:])
    }
}

/// A started fetch plus how its chips render.
nonisolated struct PRFetchSession {
    var completion: any PRFetchCompletion
    /// `#` on GitHub, `!` on GitLab.
    var numberPrefix: String
    /// Empty with the plain glyph set.
    var forgeIcon: String
}
