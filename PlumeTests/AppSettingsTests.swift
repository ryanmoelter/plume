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

    @Test func keepsPlumeShortcutsOnMacDefaultsOnAndPersists() {
        let defaults = makeDefaults()
        #expect(AppSettings(defaults: defaults).keepsPlumeShortcutsOnMac)

        AppSettings(defaults: defaults).keepsPlumeShortcutsOnMac = false
        #expect(!AppSettings(defaults: defaults).keepsPlumeShortcutsOnMac)
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

    @Test func showsLinearIssuesDefaultsToOnWhenUnset() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.showsLinearIssues)
    }

    @Test func showsLinearIssuesPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.showsLinearIssues = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.showsLinearIssues)
    }

    @Test func infoPaneDefaultsToExpanded() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.infoPaneState == .expanded)
        #expect(settings.infoPaneWidth == InfoPaneLayout.defaultPaneWidth)
        #expect(settings.infoPaneSubagentsExpanded)
        #expect(settings.infoPaneBackgroundTasksExpanded)
    }

    @Test func infoPaneSettingsPersist() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.infoPaneState = .collapsed
        settings.infoPaneWidth = 360
        settings.infoPaneSubagentsExpanded = false
        settings.infoPaneBackgroundTasksExpanded = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.infoPaneState == .collapsed)
        #expect(reloaded.infoPaneWidth == 360)
        #expect(!reloaded.infoPaneSubagentsExpanded)
        #expect(!reloaded.infoPaneBackgroundTasksExpanded)
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

    @Test func accentStartsFromTheSystemMatchOnlyOnFirstLaunch() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, initialAccentPaletteSlot: { 4 })
        #expect(settings.accentTint == .palette(slot: 4))
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { 2 }).accentTint == .palette(slot: 4))

        settings.accentTint = nil
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { 2 }).accentTint == nil)

        settings.accentTint = .palette(slot: 12)
        #expect(AppSettings(defaults: defaults).accentTint == .palette(slot: 12))
    }

    @Test func noSystemMatchStartsOnTheSystemAccent() {
        let defaults = makeDefaults()
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { nil }).accentTint == nil)
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { 2 }).accentTint == nil)
    }

    @Test func outOfRangeAccentPaletteSlotReadsAsSystem() {
        let defaults = makeDefaults()
        defaults.set(16, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == nil)
    }

    @Test func aSlotChosenBeforeAccentTintsExistedStillReads() {
        let defaults = makeDefaults()
        defaults.set(5, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { 2 }).accentTint == .palette(slot: 5))
        defaults.set(-1, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults, initialAccentPaletteSlot: { 2 }).accentTint == nil)
    }

    @Test func anAccentTintSupersedesTheOldSlot() {
        let defaults = makeDefaults()
        defaults.set(5, forKey: "accentPaletteSlot")
        let settings = AppSettings(defaults: defaults)
        settings.accentTint = .extended(.blueberry, bright: true)
        #expect(AppSettings(defaults: defaults).accentTint == .extended(.blueberry, bright: true))

        settings.accentTint = nil
        #expect(AppSettings(defaults: defaults).accentTint == nil)
    }

    @Test func aSlotOrSystemAccentStillWritesTheOldKey() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, initialAccentPaletteSlot: { nil })
        settings.accentTint = .palette(slot: 6)
        #expect(defaults.object(forKey: "accentPaletteSlot") as? Int == 6)
        settings.accentTint = .extended(.lemon, bright: false)
        #expect(defaults.object(forKey: "accentPaletteSlot") as? Int == -2)
        settings.accentTint = nil
        #expect(defaults.object(forKey: "accentPaletteSlot") as? Int == -1)
    }

    @Test func theTextColorIsNoAccent() {
        let defaults = makeDefaults()
        defaults.set("text", forKey: "accentTintRaw")
        #expect(AppSettings(defaults: defaults).accentTint == nil)

        let settings = AppSettings(defaults: defaults)
        settings.accentTint = .text
        #expect(settings.accentTint == nil)
        #expect(AppSettings(defaults: defaults).accentTint == nil)
    }

    @Test func anOlderBuildsSlotChangeWinsOverAStalePaletteTint() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accentTint = .palette(slot: 4)
        defaults.set(9, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == .palette(slot: 9))

        settings.accentTint = nil
        defaults.set(2, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == .palette(slot: 2))

        settings.accentTint = .palette(slot: 3)
        defaults.set(-1, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == nil)
    }

    @Test func anExtendedAccentHoldsWhileTheSlotKeyIsUntouched() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accentTint = .extended(.eggplant, bright: false)
        #expect(defaults.object(forKey: "accentPaletteSlot") as? Int == -2)
        #expect(AppSettings(defaults: defaults).accentTint == .extended(.eggplant, bright: false))
    }

    @Test func anOlderBuildsSlotChangeWinsOverAnExtendedTint() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.accentTint = .extended(.eggplant, bright: false)
        defaults.set(9, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == .palette(slot: 9))

        settings.accentTint = .extended(.lemon, bright: true)
        defaults.set(-1, forKey: "accentPaletteSlot")
        #expect(AppSettings(defaults: defaults).accentTint == nil)
    }

    @Test func extendedPaletteStartsOnAndPersists() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.usesExtendedPalette)

        settings.usesExtendedPalette = false
        #expect(!AppSettings(defaults: defaults).usesExtendedPalette)
        settings.usesExtendedPalette = true
        #expect(AppSettings(defaults: defaults).usesExtendedPalette)
    }

    @Test func freshInstallsMapLinearStatesToTheThemePalette() {
        #expect(AppSettings(defaults: makeDefaults()).linearStateColors == .themePalette)
    }

    @Test func theExtendedPaletteMigrationOverwritesStoredChoices() {
        let defaults = makeDefaults()
        defaults.set(LinearStateColorStrategy.ensureContrast.rawValue, forKey: "linearStateColorsRaw")
        defaults.set(false, forKey: "usesExtendedPalette")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.linearStateColors == .themePalette)
        #expect(settings.usesExtendedPalette)
    }

    @Test func choicesAfterTheExtendedPaletteMigrationStick() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.linearStateColors = .ensureContrast
        settings.usesExtendedPalette = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.linearStateColors == .ensureContrast)
        #expect(!reloaded.usesExtendedPalette)
    }

    @Test func theExtendedPaletteMigrationRunsOnce() {
        let defaults = makeDefaults()
        _ = AppSettings(defaults: defaults)
        defaults.set(LinearStateColorStrategy.ensureContrast.rawValue, forKey: "linearStateColorsRaw")
        defaults.set(false, forKey: "usesExtendedPalette")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.linearStateColors == .ensureContrast)
        #expect(!settings.usesExtendedPalette)
    }
}

@MainActor
struct RecentRemoteDeviceModelsTests {
    @Test func keepsNewestFirstWithoutDuplicatesAndCapsAtFive() {
        let defaults = UserDefaults(suiteName: "RecentRemoteDeviceModelsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        for id in ["a/1", "b/1", "c/1", "a/1", "d/1", "e/1", "f/1"] {
            settings.recordRemoteDeviceReservation(id)
        }
        #expect(settings.recentRemoteDeviceModels == ["f/1", "e/1", "d/1", "a/1", "c/1"])
        #expect(AppSettings(defaults: defaults).recentRemoteDeviceModels == settings.recentRemoteDeviceModels)
    }

    @Test func removalDropsOnlyThatModelAndPersists() {
        let defaults = UserDefaults(suiteName: "RecentRemoteDeviceModelsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        for id in ["a/1", "b/1", "c/1"] { settings.recordRemoteDeviceReservation(id) }
        settings.removeRecentRemoteDeviceModel("b/1")
        #expect(settings.recentRemoteDeviceModels == ["c/1", "a/1"])
        #expect(AppSettings(defaults: defaults).recentRemoteDeviceModels == ["c/1", "a/1"])
    }
}
