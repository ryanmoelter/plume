import Foundation

/// The naming and lookup rules commands are built on.
nonisolated enum WT {
    static let programName = "wt"

    /// The resolved branch prefix, or a failure explaining how to set one.
    static func branchPrefix(_ ctx: any WTContext) throws -> String {
        guard let prefix = ctx.branchPrefixResolution() else {
            throw CLIFailure(
                "can't derive the branch prefix: git user.email is missing or has no '@'. "
                    + "Set one in Plume's Settings ▸ Projects (an empty prefix means none)"
            )
        }
        return prefix
    }

    /// `name` with the branch prefix added unless already present. A nil
    /// `prefix` resolves the configured one; an explicit empty string means
    /// no prefix.
    static func branchFor(_ ctx: any WTContext, _ name: String, prefix: String? = nil) throws -> String {
        let prefix = try prefix ?? branchPrefix(ctx)
        if !prefix.isEmpty, name.hasPrefix(prefix) { return name }
        return prefix + name
    }

    /// The folder for a branch: everything after the first `/`, with any
    /// further `/` flattened to `-`. `ryanm/foo` → `foo`,
    /// `cc/feature/thing` → `feature-thing`.
    static func folderForBranch(_ branch: String) -> String {
        let rest = branch.firstIndex(of: "/").map { branch[branch.index(after: $0)...] } ?? Substring(branch)
        return rest.replacingOccurrences(of: "/", with: "-")
    }

    /// An existing local branch for a checkout target: an exact match, else
    /// the single branch ending in `/<name>`. Fails on zero or several.
    static func resolveBranch(_ ctx: any WTContext, _ name: String) throws -> String {
        if ctx.git.branchExists(name) { return name }
        let matches = ctx.git.localBranches().filter { $0.hasSuffix("/" + name) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw CLIFailure("no such branch: \(name) (use `wt co -b \(name)` to create one)")
        default:
            throw CLIFailure("ambiguous branch: \(name) matches \(matches.joined(separator: ", ")); use the full name")
        }
    }

    /// The `--paths` column: `.` for the root, the parent directory relative
    /// to the root inside it, absolute outside it, and empty for no path.
    static func displayLocation(_ path: String?, root: String) -> String {
        guard let path else { return "" }
        if path == root { return "." }
        if path.hasPrefix(root + "/") {
            let parent = (String(path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
            return parent.isEmpty ? "." : parent
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// The worktree with `branch` checked out, or nil.
    static func pathForBranch(_ ctx: any WTContext, _ branch: String) -> String? {
        ctx.git.worktreeRecords().first { $0.branch == branch }?.path
    }
}
