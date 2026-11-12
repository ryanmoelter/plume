import Foundation

/// What a markdown link in the chat points at, when it is something Plume can
/// show as a chip: a Linear issue, a GitHub pull request (or its Linear Diff, which lives at
/// `linear.review` under the same path), a claude.ai artifact, or a file.
nonisolated enum ReferenceTarget: Hashable, Sendable {
    /// Uppercased.
    case linear(identifier: String)
    case pullRequest(owner: String, repo: String, number: Int)
    /// From `claude.ai/artifact/<id>` or `claude.ai/code/artifact/<id>`.
    case artifact(id: String)
    /// Absolute and standardized.
    case file(path: String)

    /// Nil for anything that isn't one of these, and for a relative path
    /// with no `base` to resolve it against.
    static func classify(_ url: URL, base: URL?) -> ReferenceTarget? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return web(url)
        case nil, "file":
            return ChatLinkOpener.resolvedFileURL(for: url, relativeTo: base).map { .file(path: $0.path) }
        default:
            return nil
        }
    }

    private static func web(_ url: URL) -> ReferenceTarget? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasSuffix(".claude.ai") { host = "claude.ai" }
        let components = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "linear.app":
            guard components.count >= 3, components[1] == "issue",
                  let identifier = LinearIdentifier.normalize(components[2]) else { return nil }
            return .linear(identifier: identifier)
        case "github.com", "linear.review":
            guard components.count >= 4, components[2] == "pull",
                  let number = PullRequestMentionSource.number(in: components[3]) else { return nil }
            return .pullRequest(owner: components[0], repo: components[1], number: number)
        case "claude.ai":
            let path = components.first == "code" ? components.dropFirst() : components[...]
            guard path.count == 2, path.first == "artifact", let id = path.last,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
            return .artifact(id: id)
        default:
            return nil
        }
    }

    /// The chip title of an artifact the tab's Artifact calls never named.
    static let genericArtifactLabel = "Artifact"

    /// What a reference to this target is written as: `DROID-123`, `#12`,
    /// `Artifact`, or the file's name.
    var canonicalLabel: String {
        switch self {
        case .linear(let identifier): identifier
        case .pullRequest(_, _, let number): "#\(number)"
        case .artifact: Self.genericArtifactLabel
        case .file(let path): (path as NSString).lastPathComponent
        }
    }
}
