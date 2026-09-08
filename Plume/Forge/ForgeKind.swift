import Foundation

/// Which forge a repository's origin points at.
nonisolated enum ForgeKind: String, Sendable, Equatable {
    case github
    case gitlab
    case none
}

extension ForgeKind {
    /// Sniffs the forge from an origin URL's host, handling both ssh
    /// (`git@host:path.git`) and https forms.
    static func sniffing(originURL: String?) -> ForgeKind {
        var host = originURL ?? ""
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let range = host.range(of: "@") { host = String(host[range.upperBound...]) }
        host = String(host.prefix(while: { $0 != "/" && $0 != ":" }))

        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        return .none
    }
}
