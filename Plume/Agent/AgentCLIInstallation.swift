import Foundation

nonisolated enum AgentCLIInstallation {
    static func installedProviders() -> Set<AgentProviderKind> {
        var installed = Set<AgentProviderKind>()
        if ClaudeCLILocator.isAvailable(commandName: "claude", refresh: true) { installed.insert(.claudeCode) }
        if ClaudeCLILocator.isAvailable(commandName: "codex", refresh: true) { installed.insert(.codex) }
        return installed
    }

    /// UI-only overrides leave command lookup and running sessions untouched.
    @MainActor static func displayedProviders(_ detected: Set<AgentProviderKind>) -> Set<AgentProviderKind> {
        #if DEBUG
        return AgentInstallationDebug.shared.applying(to: detected)
        #else
        return detected
        #endif
    }

    static func downloadTitle(for provider: AgentProviderKind) -> String {
        provider == .claudeCode ? "Download Claude Code…" : "Download Codex…"
    }

    static func downloadURL(for provider: AgentProviderKind) -> URL {
        URL(string: provider == .claudeCode
            ? "https://code.claude.com/docs/en/overview"
            : "https://learn.chatgpt.com/docs/codex/cli")!
    }
}
