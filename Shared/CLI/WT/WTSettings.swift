import Foundation

/// The fallbacks applied to a project's settings when it leaves a field nil.
nonisolated enum WTSettings {
    /// `configured` when set, including an explicit empty string ("no
    /// prefix"); otherwise the local part of `userEmail` plus `/`. Nil when
    /// the email is missing or has no `@`.
    static func branchPrefix(configured: String?, userEmail: String?) -> String? {
        // TODO(PLUME-316 group B)
        nil
    }

    /// `configured` when set and non-empty, else origin's default branch from
    /// `originHead` (`origin/main` → `main`), else `main`.
    static func baseBranch(configured: String?, originHead: String?) -> String {
        // TODO(PLUME-316 group B)
        ""
    }

    /// The base branch and origin's default branch, which never show a PR.
    static func trunkBranches(baseBranch: String, originHead: String?) -> Set<String> {
        // TODO(PLUME-316 group B)
        []
    }

    /// The configured names plus `.bare` in the bare layout, or the main
    /// worktree's name in the standard one.
    static func protectedWorktrees(configured: [String]?, layout: WorktreeLayout, mainName: String) -> [String] {
        // TODO(PLUME-316 group B)
        []
    }

    /// The glyph set, palette and ignored checks the settings ask for. Color
    /// needs a terminal on stdout and no `NO_COLOR`.
    static func terminalUI(settings: ProjectSettings, stdoutIsTerminal: Bool, environment: [String: String]) -> TerminalUI {
        // TODO(PLUME-316 group B)
        .plain
    }
}
