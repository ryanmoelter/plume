import Foundation

/// A forge's CLI (`gh` or `glab`), behind one interface so callers hold a
/// backend and never branch on the forge. Both are soft dependencies: an
/// uninstalled CLI or a failed request yields nil, never an error.
nonisolated protocol ForgeBackend: Sendable {
    var kind: ForgeKind { get }
    /// `#` on GitHub, `!` on GitLab.
    var numberPrefix: String { get }
    /// `PR` on GitHub, `MR` on GitLab.
    var noun: String { get }
    var isInstalled: Bool { get }
    /// Pull requests for `branches`, or nil when the request failed or the
    /// CLI is missing, so a caller can tell "no PR" from "unreachable".
    func pullRequests(forBranches branches: [String]) -> PullRequestMap?
}

/// `gh api graphql`, chunked by `GitHubQuery.chunkSize`. `gh` resolves its
/// `{owner}`/`{repo}` placeholders from `workingDirectory`.
nonisolated struct GitHubBackend: ForgeBackend {
    var workingDirectory: String?

    /// Enough concurrent chunks to hide latency without a burst the forge's
    /// rate limiter would notice.
    static let chunkWorkers = 4

    var kind: ForgeKind { .github }
    var numberPrefix: String { "#" }
    var noun: String { "PR" }
    var isInstalled: Bool { CLIProcess.which("gh") != nil }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        if branches.isEmpty { return [:] }
        guard isInstalled else { return nil }
        let chunks = GitHubQuery.chunks(of: branches)
        if chunks.count == 1 { return fetch(chunks[0]) }

        let results = ChunkResults(count: chunks.count)
        let slots = DispatchSemaphore(value: Self.chunkWorkers)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
            slots.wait()
            defer { slots.signal() }
            results.set(index, fetch(chunks[index]))
        }
        var out: PullRequestMap = [:]
        for result in results.all {
            guard let result else { return nil }
            out.merge(result) { _, new in new }
        }
        return out
    }

    private func fetch(_ chunk: [String]) -> PullRequestMap? {
        let (query, aliasToBranch) = GitHubQuery.build(branches: chunk)
        let arguments = ["gh", "api", "graphql", "-f", "query=\(query)", "-F", "owner={owner}", "-F", "name={repo}"]
        guard let result = try? CLIProcess.run(arguments, check: false, workingDirectory: workingDirectory),
              result.status == 0,
              let decoded = try? GitHubQuery.decode(Data(result.stdout.utf8), aliasToBranch: aliasToBranch)
        else { return nil }
        return decoded.compactMapValues { $0 }
    }
}

private nonisolated final class ChunkResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PullRequestMap?]

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: PullRequestMap?) {
        lock.withLock { results[index] = value }
    }

    var all: [PullRequestMap?] {
        lock.withLock { results }
    }
}

/// `glab api graphql`, one request for every branch.
nonisolated struct GitLabBackend: ForgeBackend {
    var fullPath: String
    var workingDirectory: String?

    var kind: ForgeKind { .gitlab }
    var numberPrefix: String { "!" }
    var noun: String { "MR" }
    var isInstalled: Bool { CLIProcess.which("glab") != nil }

    func pullRequests(forBranches branches: [String]) -> PullRequestMap? {
        if branches.isEmpty { return [:] }
        guard isInstalled else { return nil }
        let query = GitLabQuery.build(fullPath: fullPath, branches: branches)
        guard let result = try? CLIProcess.run(["glab", "api", "graphql", "-f", "query=\(query)"], check: false, workingDirectory: workingDirectory),
              result.status == 0,
              let found = try? GitLabQuery.normalize(Data(result.stdout.utf8))
        else { return nil }
        return found.filter { branches.contains($0.key) }
    }
}

nonisolated enum ForgeBackends {
    /// The backend for `kind`, or nil for `.none` and for a GitLab origin
    /// whose project path can't be read.
    static func backend(for kind: ForgeKind, originURL: String?, workingDirectory: String?) -> (any ForgeBackend)? {
        switch kind {
        case .github:
            return GitHubBackend(workingDirectory: workingDirectory)
        case .gitlab:
            guard let fullPath = GitLabQuery.fullPath(originURL: originURL) else { return nil }
            return GitLabBackend(fullPath: fullPath, workingDirectory: workingDirectory)
        case .none:
            return nil
        }
    }
}
