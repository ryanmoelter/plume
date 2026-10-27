import Darwin
import Foundation

/// One tracked branch. `base` is the commit of `parent` the branch was last
/// stacked on: the lower bound for `git rebase --onto`.
nonisolated struct StackEntry: Equatable, Sendable {
    var parent: String
    var base: String
    /// Keys besides `parent` and `base`, kept so a rewrite round-trips them.
    var extra: [StackJSONMember]

    init(parent: String, base: String, extra: [StackJSONMember] = []) {
        self.parent = parent
        self.base = base
        self.extra = extra
    }
}

/// Every tracked branch by name. A stack is a tree derived from the parent
/// pointers, rooted at a branch whose parent isn't tracked.
typealias StackBranches = [String: StackEntry]

/// `branches.json`: `{"version": 2, "branches": {name: {"parent", "base"}}}`.
nonisolated enum StackStateCodec {
    static let currentVersion = 2

    enum DecodeError: Error, Equatable {
        case unreadable(String)
        /// Written by a newer `stack`; never overwrite it.
        case tooNew(Int)
    }

    static func encode(_ branches: StackBranches) -> String {
        ""
    }

    static func decode(_ data: Data) throws -> StackBranches {
        throw DecodeError.unreadable("not implemented")
    }
}

/// The state directory, `<git-common-dir>/stack`, shared by every worktree.
nonisolated final class StackStateStore {
    static let fileName = "branches.json"

    let directory: String

    init(directory: String) {
        self.directory = directory
    }

    var stateFile: String { "\(directory)/\(Self.fileName)" }

    struct LoadResult: Equatable {
        var branches: StackBranches
        /// Legacy files were merged or deleted branches pruned, in memory
        /// only.
        var dirty: Bool
    }

    func load(localBranches: Set<String>, warn: (String) -> Void) throws -> LoadResult {
        throw CLIFailure("not implemented")
    }

    func save(_ branches: StackBranches, warn: (String) -> Void) throws {
        throw CLIFailure("not implemented")
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        throw CLIFailure("not implemented")
    }
}
