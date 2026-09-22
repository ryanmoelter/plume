import Foundation
import SwiftUI
import Testing
@testable import Plume

/// Covers what a stored binding has to survive: a JSON round trip, falling
/// back to its default when unset, and never leaving two commands on one
/// chord.
@MainActor
struct ShortcutBindingsTests {
    @Test func menuShortcutRoundTripsThroughJSON() throws {
        let shortcut = MenuShortcut("j", modifiers: [.option, .shift])
        let decoded = try JSONDecoder().decode(
            MenuShortcut.self,
            from: JSONEncoder().encode(shortcut)
        )
        #expect(decoded == shortcut)
    }

    @Test func everyModifierCombinationRoundTrips() throws {
        let combinations: [EventModifiers] = [
            [], [.command], [.option], [.control], [.shift],
            [.command, .shift], [.option, .shift], [.command, .option, .control, .shift],
        ]
        for modifiers in combinations {
            let shortcut = MenuShortcut("k", modifiers: modifiers)
            let decoded = try JSONDecoder().decode(
                MenuShortcut.self,
                from: JSONEncoder().encode(shortcut)
            )
            #expect(decoded == shortcut)
        }
    }

    @Test func decodingRejectsAMultiCharacterKey() {
        let json = Data(#"{"key":"jk","modifiers":["command"]}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MenuShortcut.self, from: json)
        }
    }

    @Test func unboundActionsResolveToTheirDefaults() {
        let bindings = ShortcutBindings()
        for action in ShortcutAction.allCases {
            #expect(bindings[action] == action.defaultShortcut)
            #expect(!bindings.isCustomized(action))
        }
    }

    @Test func assigningOverridesOnlyThatAction() {
        var bindings = ShortcutBindings()
        let chord = MenuShortcut("j", modifiers: [.option])
        bindings.assign(chord, to: .nextTab)

        #expect(bindings[.nextTab] == chord)
        #expect(bindings.isCustomized(.nextTab))
        #expect(bindings[.previousTab] == ShortcutAction.previousTab.defaultShortcut)
    }

    @Test func assigningAChordAnotherActionHoldsUnbindsThatAction() {
        var bindings = ShortcutBindings()
        bindings.assign(ShortcutAction.nextTask.defaultShortcut, to: .nextTab)

        #expect(bindings[.nextTab] == ShortcutAction.nextTask.defaultShortcut)
        #expect(bindings[.nextTask] == nil)
        #expect(bindings.all.count == ShortcutAction.allCases.count - 1)
    }

    @Test func resettingRestoresTheDefault() {
        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut("j", modifiers: [.option]), to: .nextTab)
        bindings.reset(.nextTab)

        #expect(bindings[.nextTab] == ShortcutAction.nextTab.defaultShortcut)
        #expect(!bindings.isCustomized(.nextTab))
    }

    @Test func resetAllClearsEveryOverride() {
        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut("j", modifiers: [.option]), to: .nextTab)
        bindings.assign(MenuShortcut("k", modifiers: [.option]), to: .previousTab)
        bindings.resetAll()

        #expect(bindings == ShortcutBindings())
    }

    @Test func bindingsRoundTripThroughJSONIncludingUnboundActions() throws {
        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut("j", modifiers: [.option]), to: .nextTab)
        bindings.assign(ShortcutAction.nextTask.defaultShortcut, to: .previousTab)

        let decoded = try JSONDecoder().decode(
            ShortcutBindings.self,
            from: JSONEncoder().encode(bindings)
        )
        #expect(decoded == bindings)
        #expect(decoded[.nextTask] == nil)
    }

    @Test func conflictNamesTheActionAlreadyHoldingAChord() {
        let bindings = ShortcutBindings()
        #expect(bindings.conflict(for: ShortcutAction.nextTab.defaultShortcut, excluding: .nextTask) == .nextTab)
        #expect(bindings.conflict(for: MenuShortcut("j", modifiers: [.option]), excluding: .nextTab) == nil)
    }

    /// Option chords have to be claimable, or a binding the user set from the
    /// settings editor would never fire while a terminal holds focus.
    @Test func optionAndCommandChordsAreClaimableAndOthersAreNot() {
        #expect(MenuShortcut("j", modifiers: [.option]).isClaimable)
        #expect(MenuShortcut("j", modifiers: [.option, .shift]).isClaimable)
        #expect(MenuShortcut("]", modifiers: [.command, .shift]).isClaimable)
        #expect(!MenuShortcut("j", modifiers: [.control]).isClaimable)
        #expect(!MenuShortcut("j", modifiers: []).isClaimable)
    }

    @Test func aBoundOptionChordMatchesItsEvent() {
        let shortcut = MenuShortcut("j", modifiers: [.option, .shift])
        #expect(shortcut.matches(characters: "j", flags: [.option, .shift]))
        #expect(!shortcut.matches(characters: "j", flags: [.option]))
        // Caps lock must not stop an otherwise identical chord matching.
        #expect(shortcut.matches(characters: "j", flags: [.option, .shift, .capsLock]))
    }

    @Test func displayNameUsesTheStandardModifierOrder() {
        #expect(MenuShortcut("j", modifiers: [.option, .shift]).displayName == "⌥⇧J")
        #expect(MenuShortcut("]", modifiers: [.command, .shift]).displayName == "⇧⌘]")
    }

    @Test func settingsPersistBindingsAcrossReload() {
        let defaults = UserDefaults(suiteName: "ShortcutBindingsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let chord = MenuShortcut("j", modifiers: [.option])
        settings.shortcutBindings.assign(chord, to: .nextTab)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.shortcutBindings[.nextTab] == chord)
        #expect(reloaded.shortcutBindings[.previousTask] == ShortcutAction.previousTask.defaultShortcut)
    }

    @Test func settingsDefaultToNoOverrides() {
        let defaults = UserDefaults(suiteName: "ShortcutBindingsTests-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: defaults).shortcutBindings == ShortcutBindings())
    }

    @Test func fullDiskAccessPromptFlagDefaultsOffAndPersists() {
        let defaults = UserDefaults(suiteName: "ShortcutBindingsTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.hasPromptedForFullDiskAccess)

        settings.hasPromptedForFullDiskAccess = true
        #expect(AppSettings(defaults: defaults).hasPromptedForFullDiskAccess)
    }
}
