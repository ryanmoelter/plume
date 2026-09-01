import Testing
import Foundation
@testable import Plume

@MainActor
struct AppSettingsTests {
    /// A scratch `UserDefaults` suite so tests never touch the real one.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    @Test func defaultsToClaudeCodeAndNoBasePathOverride() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.providerID == ClaudeCodeProviderID)
        #expect(settings.worktreeBasePath == nil)
    }

    @Test func worktreeBasePathPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.worktreeBasePath = "/custom/base"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.worktreeBasePath == "/custom/base")
    }

    @Test func providerIDPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.providerID = "codex"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.providerID == "codex")
    }

    @Test func composerSendKeyDefaultsToCommandReturn() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.composerSendKey == .commandReturn)
    }

    @Test func composerSendKeyPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.composerSendKey = .returnKey

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.composerSendKey == .returnKey)
    }
}

@MainActor
struct AgentProviderRegistryTests {
    @Test func resolvesTheClaudeCodeID() {
        let provider = AgentProviderRegistry.provider(for: ClaudeCodeProviderID, settingsPath: nil)
        #expect(provider.id == ClaudeCodeProviderID)
    }

    @Test func unknownIDFallsBackToClaudeCode() {
        let provider = AgentProviderRegistry.provider(for: "not-a-real-provider", settingsPath: nil)
        #expect(provider.id == ClaudeCodeProviderID)
    }

    @Test func settingsPathIsForwardedToTheResolvedProvider() {
        let provider = AgentProviderRegistry.provider(for: ClaudeCodeProviderID, settingsPath: "/settings.json")
        #expect(provider.settingsPath == "/settings.json")
    }
}
