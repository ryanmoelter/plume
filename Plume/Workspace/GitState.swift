import Foundation

/// A working tree's state, as the statusline shows it.
///
/// `nonisolated` so parsing runs wherever its caller does — see `GitRunner`.
nonisolated struct GitState: Equatable {
    let branch: String?
    /// The tracked branch, from `# branch.upstream` — the only header that
    /// answers whether one is configured at all.
    let upstream: String?
    /// Nil when the counts are unavailable, which covers both a branch that
    /// tracks nothing and one whose remote-tracking ref is missing. Zero and
    /// "no counts" are different facts and the strip shows them differently.
    let ahead: Int?
    let behind: Int?
    let isDirty: Bool

    init(branch: String?, upstream: String? = nil, ahead: Int?, behind: Int?, isDirty: Bool) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDirty = isDirty
    }

    var hasUpstream: Bool { upstream != nil }

    /// Parses `git status --porcelain=v2 --branch`.
    ///
    /// `# branch.upstream` is the tracking fact; `# branch.ab` is only the
    /// counts. git prints the first without the second whenever it cannot
    /// compare — a remote-tracking ref deleted or never fetched — so reading
    /// tracking off the counts reports "no upstream" for a branch that has
    /// one.
    static func parsing(_ output: String) -> GitState {
        var branch: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var isDirty = false

        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                // A detached HEAD reports "(detached)" rather than a name.
                branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
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

        return GitState(branch: branch, upstream: upstream, ahead: ahead, behind: behind, isDirty: isDirty)
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
