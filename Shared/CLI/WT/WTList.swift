import Foundation

/// One row of `wt list`.
nonisolated struct WorktreeRow: Equatable, Sendable {
    var name: String
    /// The branch, or `<short sha> (detached)`.
    var branch: String
    /// Commits ahead of the base ref, as a string; empty on the base branch's
    /// own row, and when unanswerable.
    var ahead: String
    var dirty: Bool
    var remoteAhead: Int
    var remoteBehind: Int
    var hasUpstream: Bool

    init(name: String, branch: String, ahead: String, dirty: Bool, remoteAhead: Int, remoteBehind: Int, hasUpstream: Bool) {
        self.name = name
        self.branch = branch
        self.ahead = ahead
        self.dirty = dirty
        self.remoteAhead = remoteAhead
        self.remoteBehind = remoteBehind
        self.hasUpstream = hasUpstream
    }
}

/// The `wt list --json` payload, which the dotfiles Sublime plugin reads.
/// Every key is always present: absent values encode as `null`, never
/// omitted.
nonisolated struct WorktreeListPayload: Encodable, Equatable, Sendable {
    struct PR: Encodable, Equatable, Sendable {
        var number: Int
        var state: String
        var isDraft: Bool
        var url: String?
        var title: String?

        func encode(to encoder: any Encoder) throws {
            // TODO(PLUME-316 group C)
        }
    }

    struct Worktree: Encodable, Equatable, Sendable {
        var name: String
        var path: String?
        var branch: String
        var current: Bool
        var ahead: Int
        var dirty: Bool
        var remoteAhead: Int
        var remoteBehind: Int
        var hasUpstream: Bool
        var pr: PR?

        func encode(to encoder: any Encoder) throws {
            // TODO(PLUME-316 group C)
        }
    }

    var prState: PRState
    var worktrees: [Worktree]

    func encode(to encoder: any Encoder) throws {
        // TODO(PLUME-316 group C)
    }

    /// One line of JSON, without a trailing newline.
    func jsonString() -> String {
        // TODO(PLUME-316 group C)
        ""
    }
}

nonisolated extension WT {
    /// Worktree and branch names past this many columns are cut with an
    /// ellipsis, so one long name can't blow out the table.
    static let nameMax = 40
    /// `--json` can wait longer than the table for PR status.
    static let jsonPRWait: TimeInterval = 3
    /// The table never waits on the forge, so the fetch gets a generous
    /// budget.
    static let listPRTotal: TimeInterval = 8

    /// The plain `↗<ahead> ↑<remote ahead> ↓<remote behind> +` cluster. Width
    /// math runs on this, never on the colored twin.
    static func statusCluster(ahead: String, dirty: Bool, remoteAhead: Int = 0, remoteBehind: Int = 0) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// `statusCluster` colored: `↗` dim, `↑` `↓` `+` green.
    static func colorizeCluster(_ plain: String, ui: TerminalUI) -> String {
        // TODO(PLUME-316 group C)
        ""
    }

    /// `s` cut to `cap` columns, ending in an ellipsis when cut.
    static func truncate(_ s: String, cap: Int) -> String {
        // TODO(PLUME-316 group C)
        ""
    }

    /// A row per worktree, in list order. The base branch's own row drops its
    /// ahead count, which would only re-count what `↑` already shows.
    static func buildRows(_ ctx: any WTContext) -> [WorktreeRow] {
        // TODO(PLUME-316 group B)
        []
    }

    /// The `wt list` table, without a trailing newline.
    ///
    /// A branch without an upstream renders local-only in every state but
    /// `off`, and a trunk branch renders as having no PR. `dirs` appends the
    /// `--paths` column.
    static func renderList(
        _ rows: [WorktreeRow],
        cwdName: String?,
        prState: PRState,
        prs: PullRequestMap,
        numberPrefix: String,
        forgeIcon: String? = nil,
        trunkBranches: Set<String> = [],
        dirs: [String]? = nil,
        ui: TerminalUI = .plain
    ) -> String {
        // TODO(PLUME-316 group C)
        ""
    }

    /// The `--json` twin of `renderList`. `paths` runs parallel to `rows`,
    /// since names are not unique.
    static func buildListJSON(
        _ rows: [WorktreeRow],
        cwdName: String?,
        prState: PRState,
        prs: PullRequestMap,
        paths: [String],
        trunkBranches: Set<String> = []
    ) -> WorktreeListPayload {
        // TODO(PLUME-316 group C)
        WorktreeListPayload(prState: .off, worktrees: [])
    }

    /// Prints the table, filling in the PR column when the fetch lands.
    ///
    /// `live` (stdout is a terminal) paints a loading frame at once and
    /// redraws it in place when the fetch resolves or its budget runs out.
    /// Otherwise it waits the whole budget and prints one frame, so a piped
    /// reader never sees a stale one.
    static func printListLive(
        _ rows: [WorktreeRow],
        cwdName: String?,
        fetch: PRFetchSession?,
        trunkBranches: Set<String>,
        live: Bool,
        dirs: [String]? = nil,
        ui: TerminalUI = .plain,
        console: any CLIConsole
    ) {
        // TODO(PLUME-316 group C)
    }
}
