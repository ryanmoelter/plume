import Testing
import SwiftUI
import GhosttyTheme
@testable import Plume

/// What a view reading `@Environment(\.theme)` actually gets, per appearance.
///
/// The accent slots are `ThemeChrome`'s to resolve and are tested there. This
/// covers the layer above: that a palette built with no theme falls all the
/// way back to the system colors, and one built with a theme does not — which
/// is the difference between a themed surface and an unthemed one.
struct PaletteTests {
    private let definitions = GhosttyThemeResolver.ResolvedDefinitions(
        light: GhosttyThemeDefinition(
            name: "Lum light",
            background: "fffbf7",
            foreground: "4e463f",
            palette: [1: "ae3d62", 2: "5f9c2e", 3: "b36a00", 4: "1b94e0"]
        ),
        dark: GhosttyThemeDefinition(
            name: "Lum dark",
            background: "211a14",
            foreground: "f6ece4",
            palette: [1: "f77fa0", 2: "b6db66", 3: "ffaf5e", 4: "68bcff"]
        )
    )

    @Test func aThemedPaletteTakesItsAccentsFromTheTheme() {
        let palette = Palette(colorScheme: .dark, definitions: definitions)

        #expect(palette.danger == Color(hex: "f77fa0"))
        #expect(palette.warning == Color(hex: "ffaf5e"))
        #expect(palette.success == Color(hex: "b6db66"))
        #expect(palette.attention == Color(hex: "68bcff"))
    }

    /// The unthemed default every view outside a `plumeTheme` hierarchy gets.
    @Test func noThemeFallsBackToTheSystemAccents() {
        let palette = Palette(colorScheme: .dark, definitions: nil)

        #expect(palette.danger == .red)
        #expect(palette.warning == .orange)
        #expect(palette.success == .green)
        #expect(palette.attention == .blue)
        #expect(palette.background == nil)
        #expect(palette.foreground == .primary)
    }

    /// The symptom PLUME-146 reported: a themed surface and an unthemed one
    /// drew the same status in different colors.
    @Test func aThemedPaletteDiffersFromTheSystemFallback() {
        let themed = Palette(colorScheme: .dark, definitions: definitions)
        let unthemed = Palette(colorScheme: .dark, definitions: nil)

        #expect(themed.warning != unthemed.warning)
        #expect(themed.danger != unthemed.danger)
    }

    @Test func eachAppearanceTakesItsOwnPalette() {
        let light = Palette(colorScheme: .light, definitions: definitions)
        let dark = Palette(colorScheme: .dark, definitions: definitions)

        #expect(light.warning == Color(hex: "b36a00"))
        #expect(dark.warning == Color(hex: "ffaf5e"))
    }

    /// Selection follows the system accent in either case — it reports the
    /// user's own choice, not the terminal's.
    @Test func selectionIgnoresTheTheme() {
        #expect(Palette(colorScheme: .dark, definitions: definitions).selection == .accentColor)
        #expect(Palette(colorScheme: .dark, definitions: nil).selection == .accentColor)
    }
}
