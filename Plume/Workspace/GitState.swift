import Foundation

/// A working tree's state, as the statusline shows it.
struct GitState: Equatable {
    let branch: String?
    /// Nil when the branch tracks nothing, which is the common case on a
    /// fresh worktree branch. Zero and "no upstream" are different facts and
    /// the strip shows them differently.
    let ahead: Int?
    let behind: Int?
    let isDirty: Bool

    var hasUpstream: Bool { ahead != nil }

    /// Parses `git status --porcelain=v2 --branch`.
    ///
    /// `# branch.upstream` and `# branch.ab` are both absent when nothing is
    /// tracked, so their absence is what distinguishes "no upstream" from
    /// "level with upstream".
    static func parsing(_ output: String) -> GitState {
        var branch: String?
        var ahead: Int?
        var behind: Int?
        var isDirty = false

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                // A detached HEAD reports "(detached)" rather than a name.
                branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.ab ") {
                let counts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for count in counts {
                    if count.hasPrefix("+") { ahead = Int(count.dropFirst()) }
                    if count.hasPrefix("-") { behind = Int(count.dropFirst()) }
                }
            } else if !line.hasPrefix("#") {
                // Any non-header line is a changed, unmerged, or untracked
                // path.
                isDirty = true
            }
        }

        return GitState(branch: branch, ahead: ahead, behind: behind, isDirty: isDirty)
    }
}

extension GitRunner {
    /// One call answers branch, ahead/behind and dirty — about 30ms on a
    /// repository this size.
    static func state(in directory: String) -> GitState? {
        guard let output = try? run(["status", "--porcelain=v2", "--branch"], in: directory) else {
            return nil
        }
        return GitState.parsing(output)
    }
}
