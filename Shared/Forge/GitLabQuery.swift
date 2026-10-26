import Foundation

/// Builds GitLab's merge request query and normalizes its response into
/// `PullRequest`, so callers never branch on the forge.
nonisolated enum GitLabQuery {
    /// One query for every branch. Branch names are inlined as string
    /// literals: glab silently drops list-typed variables passed with `-f`,
    /// which would drop the filter.
    static func build(fullPath: String, branches: [String]) -> String {
        let branchList = branches.map(GitHubQuery.jsonString).joined(separator: ", ")
        return "query { project(fullPath: \(GitHubQuery.jsonString(fullPath))) { "
            + "mergeRequests(sourceBranches: [\(branchList)], first: 50, sort: CREATED_DESC) { "
            + "nodes { iid state draft sourceBranch targetBranch webUrl title diffHeadSha "
            + "approvedBy(first: 1) { nodes { username } } "
            + "reviewers(first: 5) { nodes { mergeRequestInteraction { reviewState } } } "
            + "headPipeline { status } } } } }"
    }

    struct MalformedResponse: Error {}

    /// Pipeline statuses that fold to pending. CANCELED, SKIPPED and MANUAL
    /// show no checks glyph rather than pretending they ran.
    private static let pendingPipelines: Set<String> = [
        "RUNNING", "PENDING", "CREATED", "PREPARING", "WAITING_FOR_RESOURCE", "SCHEDULED",
    ]

    /// Every source branch present in the response, keyed by branch. Among
    /// several merge requests on one branch an opened one wins, then the
    /// highest iid, compared as a number.
    static func normalize(_ data: Data) throws -> PullRequestMap {
        let root = try JSONSerialization.jsonObject(with: data)
        let nodes = (((root as? [String: Any])?["data"] as? [String: Any])?["project"] as? [String: Any])
            .flatMap { $0["mergeRequests"] as? [String: Any] }
            .flatMap { $0["nodes"] as? [[String: Any]] } ?? []

        var best: [String: (node: [String: Any], rank: (Int, Int))] = [:]
        for node in nodes {
            guard let branch = node["sourceBranch"] as? String else { throw MalformedResponse() }
            let rank = ((node["state"] as? String) == "opened" ? 1 : 0, try iid(of: node))
            if let current = best[branch], current.rank >= rank { continue }
            best[branch] = (node, rank)
        }
        return try best.mapValues { try pullRequest(from: $0.node) }
    }

    /// GitLab's GraphQL reports `iid` as a string.
    private static func iid(of node: [String: Any]) throws -> Int {
        if let number = node["iid"] as? Int { return number }
        if let text = node["iid"] as? String, let number = Int(text) { return number }
        throw MalformedResponse()
    }

    private static func pullRequest(from node: [String: Any]) throws -> PullRequest {
        let state: PullRequestState = switch node["state"] as? String {
        case "merged": .merged
        case "closed": .closed
        default: .open
        }

        let approvers = ((node["approvedBy"] as? [String: Any])?["nodes"] as? [Any]) ?? []
        let reviewers = ((node["reviewers"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let changesRequested = reviewers.contains {
            ($0["mergeRequestInteraction"] as? [String: Any])?["reviewState"] as? String == "REQUESTED_CHANGES"
        }
        // The `approved` boolean is true whenever no approvals are required,
        // so approval means anyone in `approvedBy`.
        let review: ReviewDecision = !approvers.isEmpty ? .approved : changesRequested ? .changesRequested : .none

        let pipeline = (node["headPipeline"] as? [String: Any])?["status"] as? String ?? ""
        let checks: [CheckContext] = switch pipeline {
        case "SUCCESS": [CheckContext(name: "pipeline", status: "SUCCESS")]
        case "FAILED": [CheckContext(name: "pipeline", status: "FAILURE")]
        case _ where pendingPipelines.contains(pipeline): [CheckContext(name: "pipeline", status: "PENDING")]
        default: []
        }

        return PullRequest(
            number: try iid(of: node),
            state: state,
            isDraft: node["draft"] as? Bool ?? false,
            url: node["webUrl"] as? String,
            title: node["title"] as? String,
            baseRefName: node["targetBranch"] as? String,
            headRefOid: node["diffHeadSha"] as? String,
            reviewDecision: review,
            checkContexts: checks
        )
    }

    /// The project's full path (`group/sub/repo`) from an ssh or https
    /// origin URL, for GraphQL's `project(fullPath:)`.
    static func fullPath(originURL: String?) -> String? {
        guard var rest = originURL, !rest.isEmpty else { return nil }
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if let range = rest.range(of: "@") { rest = String(rest[range.upperBound...]) }
        if let separator = rest.firstIndex(where: { $0 == "/" || $0 == ":" }) {
            rest = String(rest[rest.index(after: separator)...])
        }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        if rest.hasSuffix("/") { rest.removeLast() }
        return rest.isEmpty ? nil : rest
    }
}
