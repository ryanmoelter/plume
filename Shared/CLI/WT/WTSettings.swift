import Foundation

/// The fallbacks applied to a project's settings when it leaves a field nil.
nonisolated enum WTSettings {
    /// `configured`, normalized, when set, including an explicit empty
    /// string ("no prefix"); otherwise the local part of `userEmail` plus
    /// `/`. A whitespace-only value counts as unset. Nil when it falls back
    /// and the email is missing or has no `@`.
    static func branchPrefix(configured: String?, userEmail: String?) -> String? {
        if configured == "" { return "" }
        if let normalized = configured.map(normalizedBranchPrefix), !normalized.isEmpty { return normalized }
        guard let userEmail, let at = userEmail.firstIndex(of: "@") else { return nil }
        return String(userEmail[..<at]) + "/"
    }

    /// `prefix` without surrounding whitespace, ending in `/` unless empty.
    static func normalizedBranchPrefix(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    /// `configured` when set and non-empty, else origin's default branch from
    /// `originHead` (`origin/main` → `main`), else `main`.
    static func baseBranch(configured: String?, originHead: String?) -> String {
        if let configured, !configured.isEmpty { return configured }
        let originDefault = originDefaultBranch(originHead)
        return originDefault.isEmpty ? "main" : originDefault
    }

    /// The base branch and origin's default branch, which never show a PR.
    static func trunkBranches(baseBranch: String, originHead: String?) -> Set<String> {
        Set([baseBranch, originDefaultBranch(originHead)].filter { !$0.isEmpty })
    }

    private static func originDefaultBranch(_ originHead: String?) -> String {
        guard let originHead else { return "" }
        return originHead.hasPrefix("origin/") ? String(originHead.dropFirst("origin/".count)) : originHead
    }

    /// The configured names plus `.bare` in the bare layout, or the main
    /// worktree's name in the standard one.
    static func protectedWorktrees(configured: [String]?, layout: WorktreeLayout, mainName: String) -> [String] {
        var protected = configured ?? []
        switch layout {
        case .bare: protected.append(".bare")
        case .standard: if !mainName.isEmpty { protected.append(mainName) }
        }
        return protected
    }

    /// The glyph set, palette and ignored checks the settings ask for. Color
    /// needs a terminal on stdout and no `NO_COLOR`.
    static func terminalUI(settings: ProjectSettings, stdoutIsTerminal: Bool, environment: [String: String]) -> TerminalUI {
        let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
        return TerminalUI(
            palette: stdoutIsTerminal && !noColor ? .ansi : .plain,
            glyphSet: settings.nerdFont == true ? .nerd : .plain,
            ignoredPendingChecks: Set(settings.ignoredPendingChecks ?? [])
        )
    }
}
