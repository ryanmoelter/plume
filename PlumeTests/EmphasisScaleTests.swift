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

    /// Selection is the user's own choice, so it stays on the system accent
    /// color while every status role tracks the terminal palette.
    @Test func selectionFollowsTheSystemAccentColor() {
        #expect(ChatRole.selection == Color.accentColor)
    }

    /// A status role is either the palette's accent or the system color it
    /// used before the palette existed — never a third thing, and never nil.
    ///
    /// The test host's own ghostty config decides which branch runs, so both
    /// are accepted; `ThemeChromeTests` pins the resolution itself against
    /// explicit definitions.
    @MainActor
    @Test func statusRolesResolveToThePaletteOrTheirSystemColor() {
        let roles: [((ColorScheme) -> Color, ThemeChrome.PaletteAccent, Color)] = [
            (ChatRole.attention, .attention, .blue),
            (ChatRole.activity, .attention, .blue),
            (ChatRole.warning, .warning, .orange),
            (ChatRole.danger, .danger, .red),
            (ChatRole.success, .success, .green),
        ]

        for scheme in [ColorScheme.light, .dark] {
            for (role, accent, systemColor) in roles {
                let expected = ThemeChrome.paletteAccent(accent, for: scheme) ?? systemColor
                #expect(role(scheme) == expected)
            }
        }
    }

    /// Activity and attention carry the same news, so they must stay the same
    /// hue however they resolve — the shape is what distinguishes them.
    @MainActor
    @Test func activitySharesAttentionsHue() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(ChatRole.activity(for: scheme) == ChatRole.attention(for: scheme))
        }
    }

    /// Absent a terminal theme, a surface wash still resolves — it falls back
    /// to `.primary` at the same alpha rather than vanishing.
    @MainActor
    @Test func surfaceWashFallsBackToPrimaryWithoutATheme() {
        let unthemed = Color.chatSurface(.backgroundTint, colorScheme: .light)
        #expect(unthemed == (ThemeChrome.foreground(for: .light) ?? .primary).opacity(0.10))
    }
}
