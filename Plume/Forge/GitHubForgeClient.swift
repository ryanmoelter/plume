import Foundation
import Synchronization

/// Builds the batched GraphQL query and decodes its response.
///
/// Split from the subprocess so every part with a decision in it is testable
/// without a network or a `gh` on PATH.
nonisolated enum GitHubQuery {
    /// Branches per request. One aliased `pullRequests` field per branch is
    /// what keeps each query fast — `gh pr list` with rollups 504s on repos
    /// with big PR histories — but an unbounded alias count hits query
    /// limits.
    static let chunkSize = 30

    private static let prNodeFields = """
        number state isDraft baseRefName url title headRefOid reviewDecision \
        headRepositoryOwner { login } \
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) \
        { nodes { __typename ... on StatusContext { context state } \
        ... on CheckRun { name conclusion status } } } } } } }
        """

    static func chunks(of branches: [String]) -> [[String]] {
        stride(from: 0, to: branches.count, by: chunkSize).map {
            Array(branches[$0..<min($0 + chunkSize, branches.count)])
        }
    }

    /// The query plus the alias-to-branch map. Responses route by alias — the
    /// query never asks for `headRefName`, so there is nothing else to route
    /// by.
    static func build(branches: [String]) -> (query: String, aliasToBranch: [String: String]) {
        var fields: [String] = []
        var aliasToBranch: [String: String] = [:]
        for (index, branch) in branches.enumerated() {
            let alias = "b\(index)"
            aliasToBranch[alias] = branch
            fields.append("""
                \(alias): pullRequests(headRefName: \(jsonString(branch)), first: 10, \
                orderBy: {field: CREATED_AT, direction: DESC}) \
                { nodes { \(prNodeFields) } }
                """)
        }
        let query = "query($owner: String!, $name: String!) { "
            + "repository(owner: $owner, name: $name) { owner { login } "
            + fields.joined(separator: " ")
            + " } }"
        return (query, aliasToBranch)
    }

    /// A GraphQL string literal. Hand-rolled rather than routed through
    /// `JSONSerialization`, which escapes `/` — legal JSON, but it turns
    /// every `ryanm/branch` into an unrecognizable `ryanm\/branch`.
    static func jsonString(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let scalar where scalar.value < 0x20:
                escaped += String(format: "\\u%04x", scalar.value)
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

// MARK: - Decoding

/// The response shape, as far as anything here reads it. Every container is
/// optional: `statusCheckRollup` comes back null on a repo with no CI, and
/// `reviewDecision` null when nobody has reviewed.
nonisolated struct GitHubPRNode: Decodable, Sendable {
    struct Owner: Decodable, Sendable { let login: String? }
    struct RollupContext: Decodable, Sendable {
        let context: String?
        let state: String?
        let name: String?
        let conclusion: String?
        let status: String?
    }
    struct Contexts: Decodable, Sendable { let nodes: [RollupContext]? }
    struct Rollup: Decodable, Sendable { let contexts: Contexts? }
    struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable, Sendable { let commit: Commit? }
    struct Commits: Decodable, Sendable { let nodes: [CommitNode]? }

    let number: Int
    let state: String?
    let isDraft: Bool?
    let baseRefName: String?
    let url: String?
    let title: String?
    let headRefOid: String?
    let reviewDecision: String?
    let headRepositoryOwner: Owner?
    let commits: Commits?
}

nonisolated struct GitHubResponse: Decodable, Sendable {
    struct Nodes: Decodable, Sendable { let nodes: [GitHubPRNode]? }
    struct Repository: Decodable, Sendable {
        struct Owner: Decodable, Sendable { let login: String? }
        let owner: Owner?
        /// Aliased fields (`b0`, `b1`, …) alongside a fixed one, so the
        /// container is decoded by hand.
        let branches: [String: Nodes]

        private struct Key: CodingKey {
            let stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            owner = try container.decodeIfPresent(Owner.self, forKey: Key(stringValue: "owner")!)
            var branches: [String: Nodes] = [:]
            for key in container.allKeys where key.stringValue != "owner" {
                if let nodes = try? container.decode(Nodes.self, forKey: key) {
                    branches[key.stringValue] = nodes
                }
            }
            self.branches = branches
        }
    }
    struct Payload: Decodable, Sendable { let repository: Repository? }
    let data: Payload?
}

extension PullRequest {
    /// nil for a node whose `state` isn't one GitHub documents.
    init?(node: GitHubPRNode) {
        guard let state = PullRequestState(rawValue: node.state ?? "") else { return nil }
        let contexts = (node.commits?.nodes?.first?.commit?.statusCheckRollup?.contexts?.nodes ?? [])
            .map {
                CheckContext(
                    context: $0.context,
                    state: $0.state,
                    name: $0.name,
                    conclusion: $0.conclusion,
                    status: $0.status
                )
            }
        self.init(
            number: node.number,
            state: state,
            isDraft: node.isDraft ?? false,
            url: node.url,
            title: node.title,
            baseRefName: node.baseRefName,
            headRefOid: node.headRefOid,
            reviewDecision: ReviewDecision(rawValue: node.reviewDecision),
            checkContexts: contexts
        )
    }
}

extension GitHubQuery {
    /// The pull request a branch's column should show, from every one that
    /// shares the branch name: prefer a head in this repository over a
    /// same-named fork branch, then an open one, then the highest number.
    static func pickBest(_ nodes: [GitHubPRNode], repositoryOwner: String?) -> GitHubPRNode? {
        nodes.max { lhs, rhs in
            rank(lhs, repositoryOwner: repositoryOwner) < rank(rhs, repositoryOwner: repositoryOwner)
        }
    }

    private static func rank(
        _ node: GitHubPRNode,
        repositoryOwner: String?
    ) -> (Int, Int, Int) {
        (
            node.headRepositoryOwner?.login == repositoryOwner ? 1 : 0,
            node.state == "OPEN" ? 1 : 0,
            node.number
        )
    }

    static func normalize(
        _ response: GitHubResponse,
        aliasToBranch: [String: String]
    ) -> [String: PullRequest?] {
        let repository = response.data?.repository
        let owner = repository?.owner?.login
        var out: [String: PullRequest?] = [:]
        for (alias, branch) in aliasToBranch {
            let nodes = repository?.branches[alias]?.nodes ?? []
            let best = pickBest(nodes, repositoryOwner: owner)
            out[branch] = best.flatMap(PullRequest.init(node:))
        }
        return out
    }

    static func decode(
        _ data: Data,
        aliasToBranch: [String: String]
    ) throws -> [String: PullRequest?] {
        let response = try JSONDecoder().decode(GitHubResponse.self, from: data)
        return normalize(response, aliasToBranch: aliasToBranch)
    }
}

// MARK: - Client

/// Fetches pull requests through the `gh` CLI.
///
/// An actor for the reason `GitService` is one: the subprocess blocks its
/// thread, and the project defaults isolation to `MainActor`, so reaching it
/// has to mean `await`.
actor GitHubForgeClient: ForgeClient {
    static let shared = GitHubForgeClient()

    private let timeout: Duration

    init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    func fetchPullRequests(
        forBranches branches: [String],
        in repository: String
    ) async throws -> [String: PullRequest?] {
        if branches.isEmpty { return [:] }
        var out: [String: PullRequest?] = [:]
        for chunk in GitHubQuery.chunks(of: branches) {
            let (query, aliasToBranch) = GitHubQuery.build(branches: chunk)
            let data = try runGH(query: query, in: repository)
            out.merge(try GitHubQuery.decode(data, aliasToBranch: aliasToBranch)) { _, new in new }
        }
        return out
    }

    /// `{owner}` and `{repo}` are gh's own placeholders — it resolves them
    /// from its working directory, so they are passed literally.
    private func runGH(query: String, in repository: String) throws -> Data {
        let command = ([
            "gh", "api", "graphql",
            "-f", "query=" + query,
            "-F", "owner={owner}",
            "-F", "name={repo}",
        ] as [String]).map(shellQuoted).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A GUI-launched app inherits no shell PATH, and `gh` lives outside
        // the system directories, so it is only reachable through a login
        // shell.
        //
        // `-m` (job control) is what makes the timeout work. Without it the
        // login shell's children join Plume's own process group, so killing
        // the shell leaves `gh` alive holding the pipe's write end — the read
        // then blocks until `gh` finishes on its own, and the deadline buys
        // nothing. With it the child leads its own group, and `kill(-pid)`
        // reaps the whole tree.
        process.arguments = ["-mc", LoginShellCommand.wrap("exec " + command)]
        process.currentDirectoryURL = URL(fileURLWithPath: repository)

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw ForgeError(message: "could not run gh: \(error.localizedDescription)")
        }

        let timedOut = Mutex(false)
        let deadline = DispatchWorkItem { [processIdentifier = process.processIdentifier] in
            timedOut.withLock { $0 = true }
            kill(-processIdentifier, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: deadline)
        defer { deadline.cancel() }

        // Read both pipes before waiting: a full pipe deadlocks the child,
        // and a rollup for a busy repo is far bigger than a pipe buffer.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if timedOut.withLock({ $0 }) {
            throw ForgeError(message: "gh timed out", kind: .timedOut)
        }
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ForgeError(message: stderr.isEmpty
                ? "gh exited \(process.terminationStatus)"
                : stderr)
        }
        return outputData
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
