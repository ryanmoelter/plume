import Testing
import SwiftUI
import GhosttyTheme
@testable import Plume

/// `StatuslineColors.foreground` is what the pacing dot's own tint reads
/// from (`MeterView.dot`), so a themed palette's warning/danger reaching it
/// is what keeps the dot in step with the fill it annotates rather than
/// falling back to the system `.orange`/`.red` PLUME-146 found elsewhere.
struct StatuslineColorsTests {
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

    @Test func foregroundTakesWarningAndDangerFromAThemedPalette() {
        let colors = Palette(colorScheme: .dark, definitions: definitions)

        #expect(StatuslineColors.foreground(for: .yellow, colors: colors) == colors.warning)
        #expect(StatuslineColors.foreground(for: .red, colors: colors) == colors.danger)
        #expect(StatuslineColors.foreground(for: .yellow, colors: colors) == Color(hex: "ffaf5e"))
        #expect(StatuslineColors.foreground(for: .red, colors: colors) == Color(hex: "f77fa0"))
    }

    @Test func foregroundDiffersFromTheUnthemedSystemFallback() {
        let themed = Palette(colorScheme: .dark, definitions: definitions)
        let unthemed = Palette(colorScheme: .dark, definitions: nil)

        #expect(StatuslineColors.foreground(for: .yellow, colors: themed) != StatuslineColors.foreground(for: .yellow, colors: unthemed))
        #expect(StatuslineColors.foreground(for: .red, colors: themed) != StatuslineColors.foreground(for: .red, colors: unthemed))
    }
}
