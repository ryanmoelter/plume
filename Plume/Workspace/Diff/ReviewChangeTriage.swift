import Foundation

/// Decides which watched changes alter a working-tree review, against what
/// the last listing knew.
nonisolated struct ReviewChangeTriage: Sendable {
    /// Every listed and changed path, relative to the root. A nested
    /// repository lists as `name/`, a submodule as its bare path.
    var knownPaths: Set<String> = []
    /// The checked-out branch's full ref; nil when `HEAD` is detached.
    var headRef: String?
    var baseRef: String?

    /// The refs `defaultBaseRef` would weigh, so creating one re-resolves.
    private static let baseRefCandidates: Set<String> = [
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/main", "refs/remotes/origin/master",
        "refs/heads/main", "refs/heads/master",
    ]

    struct Outcome: Equatable {
        var relists = false
        /// `HEAD` moved, so the checked-out branch may be another.
        var headMoved = false
        var baseRefChanged = false
        /// Working-tree paths the batch named, nested repositories aside.
        var touched: Set<String> = []
        /// Touched paths the last listing didn't know. Whether they matter
        /// depends on `.gitignore`.
        var unknown: [String] = []
    }

    func triage(_ changes: [RepositoryWatchScope.Change]) -> Outcome {
        var outcome = Outcome()
        for change in changes {
            switch change {
            case .index:
                outcome.relists = true
            case .ref(let name):
                if name == "HEAD" {
                    outcome.relists = true
                    outcome.headMoved = true
                } else if name == baseRef || Self.baseRefCandidates.contains(name) {
                    outcome.relists = true
                    outcome.baseRefChanged = true
                } else if name == headRef || name == "packed-refs" {
                    outcome.relists = true
                }
            case .workingTree(let path):
                guard !isInsideNestedRepository(path) else { continue }
                outcome.touched.insert(path)
                if knownPaths.contains(path) {
                    outcome.relists = true
                } else {
                    outcome.unknown.append(path)
                }
            case .irrelevant:
                break
            }
        }
        return outcome
    }

    /// A listed ancestor means a repository of its own: `ls-files` lists an
    /// untracked nested repository as `name/` and a submodule as `name`,
    /// and never lists what is inside either.
    private func isInsideNestedRepository(_ path: String) -> Bool {
        var ancestor = Substring(path)
        while let slash = ancestor.lastIndex(of: "/") {
            ancestor = ancestor[..<slash]
            if knownPaths.contains(String(ancestor)) || knownPaths.contains(ancestor + "/") { return true }
        }
        return false
    }
}
