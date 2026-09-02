import Testing
import SwiftUI
@testable import Plume

/// The emphasis scale's two resolutions: literal alpha for fills, and the
/// semantic text hierarchy for labels.
struct EmphasisScaleTests {
    @Test func fillOpacitiesMatchTheScale() {
        #expect(Emphasis.primary.fillOpacity(for: .light) == 1)
        #expect(Emphasis.secondary.fillOpacity(for: .light) == 0.8)
        #expect(Emphasis.subtle.fillOpacity(for: .light) == 0.6)
        #expect(Emphasis.disabled.fillOpacity(for: .light) == 0.35)
    }

    /// Only the two structural levels differ by scheme; the rest are one
    /// value, so a light/dark switch cannot silently reweight body text.
    @Test func onlyStructuralLevelsVaryByColorScheme() {
        #expect(Emphasis.divider.fillOpacity(for: .light) == 0.15)
        #expect(Emphasis.divider.fillOpacity(for: .dark) == 0.20)
        #expect(Emphasis.backgroundTint.fillOpacity(for: .light) == 0.10)
        #expect(Emphasis.backgroundTint.fillOpacity(for: .dark) == 0.15)

        for emphasis in [Emphasis.primary, .secondary, .subtle, .disabled] {
            #expect(emphasis.fillOpacity(for: .light) == emphasis.fillOpacity(for: .dark))
        }
    }

    @Test func opacitiesDescendMonotonically() {
        for scheme in [ColorScheme.light, .dark] {
            let ladder = Emphasis.allCases.map { $0.fillOpacity(for: scheme) }
            #expect(ladder == ladder.sorted(by: >))
        }
    }

    @Test func textLevelsMapOntoTheSemanticHierarchy() {
        #expect(Emphasis.primary.textLevel == .primary)
        #expect(Emphasis.secondary.textLevel == .secondary)
        #expect(Emphasis.subtle.textLevel == .tertiary)
        #expect(Emphasis.disabled.textLevel == .quaternary)
    }

    /// A stray `.emphasis(.divider)` on a label should still be legible
    /// rather than resolving to something invisible.
    @Test func structuralLevelsClampToTheFaintestTextStyle() {
        #expect(Emphasis.divider.textLevel == .quaternary)
        #expect(Emphasis.backgroundTint.textLevel == .quaternary)
    }

    @Test func emphasizedAppliesTheFillOpacity() {
        #expect(Color.red.emphasized(.backgroundTint, colorScheme: .light) == Color.red.opacity(0.10))
        #expect(Color.red.emphasized(.backgroundTint, colorScheme: .dark) == Color.red.opacity(0.15))
    }

    /// Attention must not be the accent color: on macOS blue is selection,
    /// and a stalled agent has to stay distinguishable from a selected row.
    @Test func attentionIsDistinctFromSelection() {
        #expect(ChatRole.attention != ChatRole.selection)
        #expect(ChatRole.selection == Color.accentColor)
        #expect(ChatRole.attention == Color.orange)
    }

    /// Absent a terminal theme, a surface wash still resolves — it falls back
    /// to `.primary` at the same alpha rather than vanishing.
    @MainActor
    @Test func surfaceWashFallsBackToPrimaryWithoutATheme() {
        let unthemed = Color.chatSurface(.backgroundTint, colorScheme: .light)
        #expect(unthemed == (ThemeChrome.foreground(for: .light) ?? .primary).opacity(0.10))
    }
}
