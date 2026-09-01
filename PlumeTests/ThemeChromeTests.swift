import Testing
import SwiftUI
import AppKit
import GhosttyTheme
@testable import Plume

struct ThemeChromeTests {
    private let definitions = GhosttyThemeResolver.ResolvedDefinitions(
        light: GhosttyThemeDefinition(name: "Lum light", background: "fffbf7", foreground: "4e463f"),
        dark: GhosttyThemeDefinition(name: "Lum dark", background: "211a14", foreground: "f6ece4")
    )

    @Test func selectsLightDefinitionInLightScheme() {
        #expect(ThemeChrome.background(for: .light, in: definitions) == Color(hex: "fffbf7"))
        #expect(ThemeChrome.foreground(for: .light, in: definitions) == Color(hex: "4e463f"))
    }

    @Test func selectsDarkDefinitionInDarkScheme() {
        #expect(ThemeChrome.background(for: .dark, in: definitions) == Color(hex: "211a14"))
        #expect(ThemeChrome.foreground(for: .dark, in: definitions) == Color(hex: "f6ece4"))
    }

    @Test func noDefinitionsFallsBackToNil() {
        #expect(ThemeChrome.background(for: .light, in: nil) == nil)
        #expect(ThemeChrome.background(for: .dark, in: nil) == nil)
        #expect(ThemeChrome.foreground(for: .light, in: nil) == nil)
    }

    @Test func unparseableColorFallsBackToNil() {
        let broken = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(name: "Broken", background: "not-a-color", foreground: "also-bad"),
            dark: nil
        )
        #expect(ThemeChrome.background(for: .light, in: broken) == nil)
        #expect(ThemeChrome.foreground(for: .light, in: broken) == nil)
    }

    @Test func titlebarBackgroundSelectsLightOrDark() {
        #expect(ThemeChrome.titlebarBackground(forDark: false, in: definitions) == NSColor(Color(hex: "fffbf7")!))
        #expect(ThemeChrome.titlebarBackground(forDark: true, in: definitions) == NSColor(Color(hex: "211a14")!))
    }

    @Test func titlebarBackgroundFallsBackToNilWithNoTheme() {
        #expect(ThemeChrome.titlebarBackground(forDark: false, in: nil) == nil)
        #expect(ThemeChrome.titlebarBackground(forDark: true, in: nil) == nil)
    }

    @Test func titlebarBackgroundFallsBackToNilOnUnparseableColor() {
        let broken = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(name: "Broken", background: "not-a-color", foreground: "also-bad"),
            dark: nil
        )
        #expect(ThemeChrome.titlebarBackground(forDark: false, in: broken) == nil)
    }
}
