import Foundation

nonisolated enum AgentCLIInstallation {
    static func installedProviders() -> Set<AgentProviderKind> {
        var installed = Set<AgentProviderKind>()
        if ClaudeCLILocator.isAvailable(commandName: "claude", refresh: true) { installed.insert(.claudeCode) }
        if ClaudeCLILocator.isAvailable(commandName: "codex", refresh: true) { installed.insert(.codex) }
        return installed
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
