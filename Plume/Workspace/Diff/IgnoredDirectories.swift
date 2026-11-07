#if DEBUG
import Foundation

/// Folders `check-ignore` has already called ignored, so writes under them,
/// such as build output, never spawn `git` again. Cleared when a
/// `.gitignore` changes.
nonisolated struct IgnoredDirectories: Sendable {
    private(set) var directories: Set<String> = []

    func covers(_ path: String) -> Bool {
        Self.ancestors(of: path).contains { directories.contains($0) }
    }

    /// Each path and every folder above it, so one `check-ignore` learns
    /// which folders to remember.
    static func queries(for paths: [String]) -> [String] {
        var seen: Set<String> = []
        var queries: [String] = []
        for path in paths {
            for candidate in [path] + ancestors(of: path) where seen.insert(candidate).inserted {
                queries.append(candidate)
            }
        }
        return queries
    }

    /// Keeps each ignored folder above one of `paths`. A path itself may be a
    /// file, so it is never remembered on its own account.
    mutating func record(ignored: Set<String>, above paths: [String]) {
        for path in paths {
            for ancestor in Self.ancestors(of: path) where ignored.contains(ancestor) {
                directories.insert(ancestor)
            }
        }
    }

    mutating func removeAll() {
        directories.removeAll()
    }

    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            if !current.isEmpty { result.append(String(current)) }
        }
        return result
    }
}
#endif
