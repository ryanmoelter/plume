#if DEBUG
import Foundation

/// What a working-tree review compares the files on disk against.
nonisolated enum ReviewBase: String, CaseIterable, Hashable, Sendable {
    /// The merge base with the branch `stack` records as this one's parent.
    case stackParent
    /// The merge base with origin's default branch.
    case originDefault
    /// The merge base with `@{upstream}`.
    case upstream
    /// Uncommitted changes only.
    case head
    /// The last commit plus uncommitted changes: `HEAD~1` against the disk.
    case previousCommit
}

/// The bases a repository offers right now, each resolved to the ref it
/// reads from.
nonisolated struct ReviewBaseOptions: Equatable, Sendable {
    /// A full ref, `refs/heads/<parent>`.
    var stackParent: String?
    var originDefault: GitDiffEngine.BaseRef
    /// A full ref, such as `refs/remotes/origin/topic`.
    var upstream: String?
    var hasPreviousCommit: Bool

    var available: [ReviewBase] {
        ReviewBase.allCases.filter { ref(for: $0) != nil }
    }

    var defaultBase: ReviewBase { stackParent != nil ? .stackParent : .originDefault }

    /// What `git` reads the base from. A merge base is taken against `HEAD`
    /// for every base but `.head` and `.previousCommit`.
    func ref(for base: ReviewBase) -> String? {
        switch base {
        case .stackParent: stackParent
        case .originDefault: originDefault.ref
        case .upstream: upstream
        case .head: "HEAD"
        case .previousCommit: hasPreviousCommit ? "HEAD~1" : nil
        }
    }

    /// The ref whose move changes the range. `HEAD` itself is watched
    /// regardless, so the two bases it anchors need nothing more.
    func watchedRef(for base: ReviewBase) -> String? {
        switch base {
        case .head, .previousCommit: nil
        default: ref(for: base)
        }
    }

    func title(for base: ReviewBase) -> String {
        switch base {
        case .stackParent: stackParent.map { Self.shortName($0) } ?? "Stack parent"
        case .originDefault: originDefault.displayName
        case .upstream: upstream.map { Self.shortName($0) } ?? "Upstream"
        case .head: "HEAD"
        case .previousCommit: "HEAD~1"
        }
    }

    func menuTitle(for base: ReviewBase) -> String {
        switch base {
        case .stackParent: "Stack parent (\(title(for: base)))"
        case .originDefault: title(for: base)
        case .upstream: "Upstream (\(title(for: base)))"
        case .head: "Uncommitted changes (HEAD)"
        case .previousCommit: "Since the previous commit (HEAD~1)"
        }
    }

    private static func shortName(_ ref: String) -> String {
        GitDiffEngine.BaseRef(ref: ref).displayName
    }

    /// The parent `stack` records for `branch`, when that parent is itself
    /// tracked. A root's parent is the trunk, which `.originDefault` covers.
    static func stackParent(of branch: String, in branches: StackBranches) -> String? {
        guard !StackGraph.parentIsTrunk(branches, branch), let parent = branches[branch]?.parent else { return nil }
        return "refs/heads/\(parent)"
    }
}

nonisolated extension GitDiffEngine {
    /// Resolves every base the repository offers. `headRef` is the checked-out
    /// branch's full ref, nil when `HEAD` is detached.
    static func baseOptions(in root: String, headRef: String?) -> ReviewBaseOptions {
        let branch = headRef.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let upstream = branch
            .flatMap { try? GitRunner.run(["rev-parse", "--symbolic-full-name", "\($0)@{upstream}"], in: root) }
            .flatMap { $0.hasPrefix("refs/") ? $0 : nil }
        let hasPreviousCommit = (try? GitRunner.run(["rev-parse", "--verify", "--quiet", "HEAD~1"], in: root)) != nil
        return ReviewBaseOptions(
            stackParent: headRef.flatMap { stackParent(of: $0, in: root) },
            originDefault: defaultBaseRef(in: root),
            upstream: upstream,
            hasPreviousCommit: hasPreviousCommit
        )
    }

    /// Reads `stack`'s own state, as `stack` itself loads it.
    private static func stackParent(of headRef: String, in root: String) -> String? {
        let prefix = "refs/heads/"
        guard headRef.hasPrefix(prefix),
              let common = try? GitRunner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root),
              let refs = try? GitRunner.run(["for-each-ref", "--format=%(refname)", prefix], in: root)
        else { return nil }
        let localBranches = Set(refs.split(separator: "\n").map { String($0.dropFirst(prefix.count)) })
        let store = StackStateStore(directory: "\(common)/stack")
        guard let branches = try? store.load(localBranches: localBranches, warn: { _ in }).branches else { return nil }
        return ReviewBaseOptions.stackParent(of: String(headRef.dropFirst(prefix.count)), in: branches)
    }

    static func resolveWorkingTree(base: ReviewBase, options: ReviewBaseOptions, root: String) throws -> ResolvedDiffRange {
        guard let ref = options.ref(for: base) else {
            throw GitError(command: "git diff", status: 0, stderr: "No \(base.rawValue) base")
        }
        switch base {
        case .head, .previousCommit:
            let commit = try GitRunner.run(["rev-parse", "--verify", "\(ref)^{commit}"], in: root)
            return ResolvedDiffRange(repositoryRoot: root, revisions: [commit], includesUntracked: true, baseCommit: commit)
        case .stackParent, .originDefault, .upstream:
            return try resolveWorkingTree(baseRef: ref, root: root)
        }
    }
}
#endif
