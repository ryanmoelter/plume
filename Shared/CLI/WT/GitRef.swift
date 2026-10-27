import Foundation

/// Full ref names for revision positions. Git resolves `refs/tags/<name>`
/// before `refs/heads/<name>`, so a bare branch name there can name a tag.
nonisolated enum GitRef {
    static func local(_ branch: String) -> String { "refs/heads/\(branch)" }
    static func origin(_ branch: String) -> String { "refs/remotes/origin/\(branch)" }
}
