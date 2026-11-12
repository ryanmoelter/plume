import Foundation

nonisolated enum PullRequestDestination: String, CaseIterable, Identifiable, Sendable {
    case linearDiffs
    case github

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linearDiffs: "Linear Diffs"
        case .github: "GitHub"
        }
    }

    /// Linear Diffs opens a GitHub pull request when `github.com` becomes
    /// `linear.review` (https://linear.app/docs/diffs), and GitHub does the
    /// reverse for a Linear Diff. Any other URL stays as it is.
    func openingURL(for url: URL) -> URL {
        let (from, to) = switch self {
        case .linearDiffs: ("github.com", "linear.review")
        case .github: ("linear.review", "github.com")
        }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == from
        else { return url }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.host = to
        components.path = "/" + parts.prefix(4).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}
