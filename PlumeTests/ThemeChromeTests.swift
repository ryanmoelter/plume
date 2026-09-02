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

    // MARK: - Palette accents

    /// A theme with a full 16-color palette.
    private let palettedDefinitions = GhosttyThemeResolver.ResolvedDefinitions(
        light: GhosttyThemeDefinition(
            name: "Paletted light",
            background: "ffffff",
            foreground: "000000",
            palette: [
                1: "a01010", 2: "106010", 3: "805000", 4: "1030a0",
                9: "ff4040", 10: "40c040", 11: "e0b000", 12: "5080ff",
            ]
        ),
        dark: GhosttyThemeDefinition(
            name: "Paletted dark",
            background: "101010",
            foreground: "ffffff",
            palette: [
                1: "a01010", 2: "106010", 3: "805000", 4: "1030a0",
                9: "ff4040", 10: "40c040", 11: "e0b000", 12: "5080ff",
            ]
        )
    )

    @Test func lightSchemeReadsTheNormalSlot() {
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: palettedDefinitions) == Color(hex: "a01010"))
        #expect(ThemeChrome.paletteAccent(.success, for: .light, in: palettedDefinitions) == Color(hex: "106010"))
        #expect(ThemeChrome.paletteAccent(.warning, for: .light, in: palettedDefinitions) == Color(hex: "805000"))
        #expect(ThemeChrome.paletteAccent(.attention, for: .light, in: palettedDefinitions) == Color(hex: "1030a0"))
    }

    @Test func darkSchemeReadsTheSameSlots() {
        #expect(ThemeChrome.paletteAccent(.danger, for: .dark, in: palettedDefinitions) == Color(hex: "a01010"))
        #expect(ThemeChrome.paletteAccent(.success, for: .dark, in: palettedDefinitions) == Color(hex: "106010"))
        #expect(ThemeChrome.paletteAccent(.warning, for: .dark, in: palettedDefinitions) == Color(hex: "805000"))
        #expect(ThemeChrome.paletteAccent(.attention, for: .dark, in: palettedDefinitions) == Color(hex: "1030a0"))
    }

    /// Light and dark resolve independently, so one side having no usable
    /// palette never reaches across to the other.
    @Test func schemesResolveIndependently() {
        let darkOnlyPalette = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(name: "Bare light", background: "ffffff", foreground: "000000"),
            dark: palettedDefinitions.dark
        )
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: darkOnlyPalette) == nil)
        #expect(ThemeChrome.paletteAccent(.danger, for: .dark, in: darkOnlyPalette) == Color(hex: "a01010"))
    }

    /// A theme that defines only the bright half still supplies an accent.
    @Test func missingNormalSlotFallsThroughToTheBrightVariant() {
        let brightOnly = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(
                name: "Bright only",
                background: "ffffff",
                foreground: "000000",
                palette: [9: "c02020"]
            ),
            dark: nil
        )
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: brightOnly) == Color(hex: "c02020"))
    }

    @Test func missingSlotFallsBackToNil() {
        let partial = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(
                name: "Partial",
                background: "ffffff",
                foreground: "000000",
                palette: [1: "a01010"]
            ),
            dark: nil
        )
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: partial) == Color(hex: "a01010"))
        #expect(ThemeChrome.paletteAccent(.success, for: .light, in: partial) == nil)
    }

    @Test func unparseablePaletteEntryFallsBackToNil() {
        let broken = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(
                name: "Broken palette",
                background: "ffffff",
                foreground: "000000",
                palette: [1: "not-a-color", 9: "#zzzzzz"]
            ),
            dark: nil
        )
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: broken) == nil)
    }

    @Test func noDefinitionsFallsBackToNilForAccents() {
        #expect(ThemeChrome.paletteAccent(.warning, for: .light, in: nil) == nil)
        #expect(ThemeChrome.paletteAccent(.warning, for: .dark, in: nil) == nil)
    }

    /// A palette this close to its own background is the user's own choice,
    /// so it is drawn as written rather than second-guessed.
    @Test func aLowContrastAccentIsStillUsed() {
        let washedOut = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(
                name: "Washed out",
                background: "fffbf7",
                foreground: "4e463f",
                palette: [3: "f5e6a0", 11: "fff4c0"]
            ),
            dark: nil
        )
        #expect(ThemeChrome.paletteAccent(.warning, for: .light, in: washedOut) == Color(hex: "f5e6a0"))
    }

    /// A role keeps its slot across appearances, so switching the system
    /// theme never changes which hue a status carries — only which palette it
    /// is read from.
    @Test func bothSchemesReadTheSameSlot() {
        let sharedBrights = GhosttyThemeResolver.ResolvedDefinitions(
            light: GhosttyThemeDefinition(
                name: "Shared brights light",
                background: "fffbf7",
                foreground: "4e463f",
                palette: [1: "ae3d62", 9: "b73060"]
            ),
            dark: GhosttyThemeDefinition(
                name: "Shared brights dark",
                background: "211a14",
                foreground: "f6ece4",
                palette: [1: "f77fa0", 9: "b73060"]
            )
        )
        // Slot 1 in both, rather than the brights a per-scheme preference
        // would have reached for in dark.
        #expect(ThemeChrome.paletteAccent(.danger, for: .light, in: sharedBrights) == Color(hex: "ae3d62"))
        #expect(ThemeChrome.paletteAccent(.danger, for: .dark, in: sharedBrights) == Color(hex: "f77fa0"))
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
