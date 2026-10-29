import Foundation

/// Which forge a repository's origin points at.
nonisolated enum ForgeKind: String, Codable, Sendable, Equatable {
    case github
    case gitlab
    case none
}

nonisolated extension ForgeKind {
    /// `override` (a project's `forge` setting) wins: the escape hatch for a
    /// self-hosted host the sniff can't classify. Otherwise sniffed from the
    /// origin URL.
    static func resolving(originURL: String?, override: ForgeKind?) -> ForgeKind {
        override ?? sniffing(originURL: originURL)
    }
}

nonisolated extension ForgeKind {
    /// Sniffs the forge from an origin URL's host, handling both ssh
    /// (`git@host:path.git`) and https forms.
    nonisolated static func sniffing(originURL: String?) -> ForgeKind {
        var host = originURL ?? ""
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let range = host.range(of: "@") { host = String(host[range.upperBound...]) }
        host = String(host.prefix(while: { $0 != "/" && $0 != ":" }))

        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        return .none
    }
}
