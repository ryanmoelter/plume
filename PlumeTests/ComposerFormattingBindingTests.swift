import AppKit
import SwiftUI
import Testing
@testable import Plume

@MainActor
struct ComposerFormattingBindingTests {
    @Test func defaultsKeepCommandBIEK() {
        let bindings = ShortcutBindings()
        for (key, style) in [("b", ComposerInlineFormatting.Style.bold), ("i", .italic), ("e", .code), ("k", .link)] {
            #expect(ComposerInlineFormatting.Style(characters: key, flags: .command, bindings: bindings) == style)
        }
        #expect(ComposerInlineFormatting.Style(characters: "b", flags: [.command, .shift], bindings: bindings) == nil)
    }

    @Test func aReboundChordReplacesTheDefault() {
        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut(MenuShortcut.backspace, modifiers: [.command, .option]), to: .formatCode)

        #expect(ComposerInlineFormatting.Style(characters: "\u{7F}", flags: [.command, .option], bindings: bindings) == .code)
        #expect(ComposerInlineFormatting.Style(characters: "e", flags: .command, bindings: bindings) == nil)
    }

    @Test func composerChordsStayOutOfTheClaimedShortcuts() {
        #expect(!ShortcutBindings().all.contains(MenuShortcut("b")))
        #expect(!PlumeShortcuts.all(with: ShortcutBindings()).contains(MenuShortcut("k")))
    }

    @Test func takingAnotherActionsChordUnbindsIt() {
        var bindings = ShortcutBindings()
        bindings.assign(MenuShortcut("b"), to: .formatItalic)
        #expect(bindings[.formatBold] == nil)
    }

    @Test func backspaceChordRoundTripsThroughItsDisplayName() {
        let chord = MenuShortcut(MenuShortcut.backspace, modifiers: [.command, .option])
        #expect(chord.displayName == "⌥⌘⌫")
        #expect(MenuShortcut(displayName: chord.displayName) == chord)
    }
}
