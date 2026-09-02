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

    /// The titlebar tint resolves its own variant per draw, so both are
    /// checked through the appearance rather than by asking for one.
    @MainActor
    @Test func titlebarBackgroundResolvesPerAppearance() throws {
        let tint = try #require(ThemeChrome.titlebarBackground(in: definitions))

        #expect(tint.resolved(forDark: false) == NSColor(Color(hex: "fffbf7")!))
        #expect(tint.resolved(forDark: true) == NSColor(Color(hex: "211a14")!))
    }

    @Test func titlebarBackgroundFallsBackToNilWithNoTheme() {
        #expect(ThemeChrome.titlebarBackground(in: nil) == nil)
    }

    /// One unusable side is enough to fall back: a dynamic color has to be
    /// able to answer for both appearances.
    @Test func titlebarBackgroundFallsBackToNilWhenEitherSideIsMissing() {
        let unparseableLight = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(name: "Broken", background: "not-a-color", foreground: "also-bad"),
            dark: definitions.dark
        )
        #expect(ThemeChrome.titlebarBackground(in: unparseableLight) == nil)

        let darkOnly = GhosttyThemeResolver.ResolvedDefinitions(light: nil, dark: definitions.dark)
        #expect(ThemeChrome.titlebarBackground(in: darkOnly) == nil)
    }
}

private extension NSColor {
    /// The variant this color resolves to in the given appearance, so a
    /// dynamic color can be compared against a plain one.
    @MainActor
    func resolved(forDark isDark: Bool) -> NSColor {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: self.cgColor)!
        }
        return resolved
    }
}
