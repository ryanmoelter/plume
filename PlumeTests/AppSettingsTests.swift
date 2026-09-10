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

    @Test func bothChatAnimationsDefaultOnAndPersistSeparately() {
        let defaults = makeDefaults()
        #expect(AppSettings(defaults: defaults).animateChatMotion)
        #expect(AppSettings(defaults: defaults).animateCharacterReveal)

        let settings = AppSettings(defaults: defaults)
        settings.animateChatMotion = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.animateChatMotion)
        #expect(reloaded.animateCharacterReveal)
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

    @Test func defaultPermissionModeDefaultsToFollowingClaudeCode() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.defaultPermissionMode == .followClaudeCode)
    }

    @Test func defaultPermissionModePersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.defaultPermissionMode = .plan

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.defaultPermissionMode == .plan)
    }

    @Test func resolvedDefaultPermissionModeReturnsThePinnedModeDirectly() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.defaultPermissionMode = .bypassPermissions
        #expect(settings.resolvedDefaultPermissionMode == .bypassPermissions)
    }

    /// Never nil, so the composer's effort control always has a value to show.
    @Test func defaultEffortFallsBackToMedium() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.defaultEffort == .medium)
    }

    @Test func defaultEffortPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.defaultEffort = .xhigh

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.defaultEffort == .xhigh)
    }

    @Test func showsPullRequestStatusDefaultsToOnWhenUnset() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.showsPullRequestStatus)
    }

    @Test func showsPullRequestStatusPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.showsPullRequestStatus = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.showsPullRequestStatus)
    }

    /// A finished turn is frequent enough that notifying on every one is a
    /// nuisance, so it stays off until asked for.
    @Test func notifiesOnTurnEndDefaultsToOffWhenUnset() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(!settings.notifiesOnTurnEnd)
    }

    @Test func notifiesOnTurnEndPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.notifiesOnTurnEnd = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.notifiesOnTurnEnd)
    }

    @Test func ignoredPendingChecksDefaultsToEmpty() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.ignoredPendingChecks.isEmpty)
    }

    @Test func ignoredPendingChecksPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.ignoredPendingChecks = ["flaky-lint", "slow-e2e"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.ignoredPendingChecks == ["flaky-lint", "slow-e2e"])
    }

    @Test func ignoredPendingChecksTrimsBlankEntriesOnWrite() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.ignoredPendingChecks = ["real-check", "  ", ""]

        #expect(settings.ignoredPendingChecks == ["real-check"])
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.ignoredPendingChecks == ["real-check"])
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
