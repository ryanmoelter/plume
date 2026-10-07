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

    /// The suite name doubles as the persistent domain name `resolveComposerSendKey`
    /// checks — `UserDefaults` exposes no way to read a suite's own name back.
    private func makeDefaultsWithDomainName() -> (UserDefaults, String) {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test func defaultsToClaudeCodeAndNoBasePathOverride() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.defaultProvider == .claudeCode)
        #expect(settings.worktreeBasePath == nil)
    }

    @Test func worktreeBasePathPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.worktreeBasePath = "/custom/base"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.worktreeBasePath == "/custom/base")
    }

    @Test func defaultProviderPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.defaultProvider = .codex

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.defaultProvider == .codex)
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

    @Test func composerSendKeyDefaultsToReturnOnAFreshInstall() {
        let (defaults, domainName) = makeDefaultsWithDomainName()
        let settings = AppSettings(defaults: defaults, domainName: domainName)
        #expect(settings.composerSendKey == .returnKey)
    }

    /// An install that predates the new default is any domain `AppSettings`
    /// has already run in — simulated here by writing some unrelated old key
    /// to the domain, without ever storing a composer send key. Deliberately
    /// not `showsCodexFullAccess`: that key only exists from 0.13.0 on, so an
    /// older install must still read as existing without it.
    @Test func composerSendKeyDefaultsToCommandReturnOnAnExistingInstallAndPersistsTheChoice() {
        let (defaults, domainName) = makeDefaultsWithDomainName()
        defaults.set(true, forKey: "someUnrelatedOldKey")

        let settings = AppSettings(defaults: defaults, domainName: domainName)
        #expect(settings.composerSendKey == .commandReturn)

        let reloaded = AppSettings(defaults: defaults, domainName: domainName)
        #expect(reloaded.composerSendKey == .commandReturn)
    }

    @Test func composerSendKeyExplicitStoredValueWinsRegardlessOfInstallAge() {
        let (defaults, domainName) = makeDefaultsWithDomainName()
        defaults.set(ComposerSendKey.returnKey.rawValue, forKey: "composerSendKeyRaw")

        let settings = AppSettings(defaults: defaults, domainName: domainName)
        #expect(settings.composerSendKey == .returnKey)
    }

    @Test func composerSendKeyPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.composerSendKey = .commandReturn

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.composerSendKey == .commandReturn)
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

    @Test func codexPermissionProfileDefaultsToWorkspaceAndPersists() {
        let suite = "AppSettingsTests.codexPermissions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.defaultCodexPermissionProfile == .codexWorkspace)
        settings.defaultCodexPermissionProfileRaw = AgentPermissionPreset.codexReadOnly.id
        #expect(AppSettings(defaults: defaults).defaultCodexPermissionProfile == .codexReadOnly)
    }

    @Test func resolvedDefaultPermissionModeReturnsThePinnedModeDirectly() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.defaultPermissionMode = .bypassPermissions
        #expect(settings.resolvedDefaultPermissionMode == .bypassPermissions)
    }

    @Test func defaultClaudeModelDefaultsToFollowingClaudeCode() {
        #expect(AppSettings(defaults: makeDefaults()).defaultClaudeModel == .followClaudeCode)
    }

    @Test func defaultClaudeModelPersists() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).defaultClaudeModel = .model(.opus5dot5)

        #expect(AppSettings(defaults: defaults).defaultClaudeModel == .model(.opus5dot5))
    }

    @Test func resolvedDefaultModelReturnsThePinnedModelDirectly() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.defaultClaudeModel = .model(.sonnet5)
        #expect(settings.resolvedDefaultModel == .sonnet5)
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

    @Test func infoPaneDefaultsToAnExpandedSidePane() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.infoPanePresentation == .side)
        #expect(settings.infoPaneState == .expanded)
        #expect(settings.infoPaneSubagentsExpanded)
    }

    @Test func infoPaneSettingsPersist() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.infoPanePresentation = .inline
        settings.infoPaneState = .collapsed
        settings.infoPaneSubagentsExpanded = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.infoPanePresentation == .inline)
        #expect(reloaded.infoPaneState == .collapsed)
        #expect(!reloaded.infoPaneSubagentsExpanded)
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
    @Test func resolvesEachProviderToItsOwnImplementation() {
        #expect(AgentProviderRegistry.provider(for: .claudeCode, settingsPath: nil).kind == .claudeCode)
        #expect(AgentProviderRegistry.provider(for: .codex, settingsPath: nil).kind == .codex)
    }

    @Test func settingsPathIsForwardedToTheResolvedProvider() {
        let provider = AgentProviderRegistry.provider(for: .claudeCode, settingsPath: "/settings.json")
        #expect((provider as? ClaudeCodeProvider)?.settingsPath == "/settings.json")
    }
}
