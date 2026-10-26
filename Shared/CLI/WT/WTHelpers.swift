import Foundation

/// The naming and lookup rules commands are built on.
nonisolated enum WT {
    static let programName = "wt"

    /// The resolved branch prefix, or a failure explaining how to set one.
    static func branchPrefix(_ ctx: any WTContext) throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// `name` with the branch prefix added unless already present. A nil
    /// `prefix` resolves the configured one; an explicit empty string means
    /// no prefix.
    static func branchFor(_ ctx: any WTContext, _ name: String, prefix: String? = nil) throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// The folder for a branch: everything after the first `/`, with any
    /// further `/` flattened to `-`. `ryanm/foo` → `foo`,
    /// `cc/feature/thing` → `feature-thing`.
    static func folderForBranch(_ branch: String) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// An existing local branch for a checkout target: an exact match, else
    /// the single branch ending in `/<name>`. Fails on zero or several.
    static func resolveBranch(_ ctx: any WTContext, _ name: String) throws -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// The `--paths` column: `.` for the root, the parent directory relative
    /// to the root inside it, absolute outside it, and empty for no path.
    static func displayLocation(_ path: String?, root: String) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// The worktree with `branch` checked out, or nil.
    static func pathForBranch(_ ctx: any WTContext, _ branch: String) -> String? {
        // TODO(PLUME-316 group B)
        nil
    }
}
