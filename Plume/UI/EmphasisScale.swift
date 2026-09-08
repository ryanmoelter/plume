import SwiftUI

/// How strongly a piece of chrome asserts itself, from body text down to a
/// barely-there background wash.
///
/// One scale, two resolutions. Text resolves through AppKit's semantic
/// hierarchy (`.primary` … `.quaternary`), which is vibrancy-aware and honors
/// Accessibility's "Increase contrast"; a flat alpha multiplier on a label
/// bypasses both and can fail contrast outright. Fills, borders and washes
/// resolve to literal alpha over the terminal theme's foreground, because
/// there is no semantic equivalent for "10% of the chat surface".
enum Emphasis: CaseIterable {
    /// Body text and anything the reader is meant to act on.
    case primary
    /// Supporting text: captions, descriptions, metadata.
    case secondary
    /// Labels the reader scans past — field keys, hints, counts.
    case subtle
    /// Present but inert.
    case disabled
    /// Hairlines and rule strokes.
    case divider
    /// A wash that separates a card from the surface behind it.
    case backgroundTint

    /// Alpha for fills, strokes and washes drawn over the chat surface.
    ///
    /// Dark themes need a slightly stronger wash for the same apparent
    /// separation: a light foreground over a dark ground reads dimmer than the
    /// reverse at equal alpha.
    func fillOpacity(for colorScheme: ColorScheme) -> Double {
        let isDark = colorScheme == .dark
        switch self {
        case .primary: return 1
        case .secondary: return 0.8
        case .subtle: return 0.6
        case .disabled: return 0.35
        case .divider: return isDark ? 0.20 : 0.15
        case .backgroundTint: return isDark ? 0.15 : 0.10
        }
    }

    /// Which rung of AppKit's semantic label hierarchy this level reads as.
    ///
    /// `.divider` and `.backgroundTint` are not text levels; they clamp to
    /// `.quaternary` so a stray `.emphasis(.divider)` on a label degrades to
    /// the faintest legible style instead of an invisible one.
    var textLevel: TextLevel {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .subtle: return .tertiary
        case .disabled, .divider, .backgroundTint: return .quaternary
        }
    }

    /// The four semantic label styles, named so the mapping is testable —
    /// `HierarchicalShapeStyle` is not `Equatable`.
    enum TextLevel {
        case primary, secondary, tertiary, quaternary

        var style: HierarchicalShapeStyle {
            switch self {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .quaternary: return .quaternary
            }
        }
    }

    var textHierarchy: HierarchicalShapeStyle { textLevel.style }
}

/// Semantic color roles, so no view reaches for a literal `Color.orange` or
/// `Color.blue`.
///
/// Status hues come from the terminal theme's ANSI palette, which is what
/// makes the chat read as part of the same surface as the terminal beside it.
/// Each falls back to its system color whenever the palette can't supply a
/// readable one, so an unthemed ghostty config looks exactly as it did before
/// the palette existed.
///
/// Selection stays on the system accent color: it marks the user's own choice,
/// not the agent's state, and macOS-wide that is the accent color's job.
enum ChatRole {
    /// The agent is waiting on the user, and nothing is wrong — a question to
    /// answer, a reply worth reading. Informational, so blue.
    static func attention(for colorScheme: ColorScheme) -> Color {
        ThemeChrome.attentionAccent(for: colorScheme) ?? .blue
    }

    /// The agent wants to do something the user should look at first, or a
    /// condition worth knowing about. A tool asking for permission is this,
    /// not `attention`: the answer carries consequences.
    static func warning(for colorScheme: ColorScheme) -> Color {
        ThemeChrome.warningAccent(for: colorScheme) ?? .orange
    }

    /// Destructive or failed.
    static func danger(for colorScheme: ColorScheme) -> Color {
        ThemeChrome.dangerAccent(for: colorScheme) ?? .red
    }

    /// Succeeded.
    static func success(for colorScheme: ColorScheme) -> Color {
        ThemeChrome.successAccent(for: colorScheme) ?? .green
    }

    /// A pull request that landed.
    static func merged(for colorScheme: ColorScheme) -> Color {
        ThemeChrome.mergedAccent(for: colorScheme) ?? .purple
    }

    /// The user's choice, and only that. Follows the system accent color.
    static let selection = Color.accentColor

    /// A turn in flight. Shares `attention`'s hue because it carries the same
    /// news — the agent, nothing wrong — and the shape tells them apart: a
    /// pulsing dot while it works, a steady mark once it wants the user.
    static func activity(for colorScheme: ColorScheme) -> Color {
        attention(for: colorScheme)
    }
}

extension ShapeStyle where Self == Color {
    /// The terminal theme's foreground at this emphasis, for washes and
    /// hairlines drawn on the chat surface.
    ///
    /// Falls back to `.primary`, which carries the same meaning against
    /// default chrome.
    static func chatSurface(_ emphasis: Emphasis, colorScheme: ColorScheme) -> Color {
        (ThemeChrome.foreground(for: colorScheme) ?? .primary)
            .opacity(emphasis.fillOpacity(for: colorScheme))
    }
}

extension Color {
    /// This color at the given emphasis — for tinting a semantic role's own
    /// fill or border, as in an attention card's wash.
    func emphasized(_ emphasis: Emphasis, colorScheme: ColorScheme) -> Color {
        opacity(emphasis.fillOpacity(for: colorScheme))
    }
}

private struct EmphasisModifier: ViewModifier {
    let emphasis: Emphasis

    func body(content: Content) -> some View {
        content.foregroundStyle(emphasis.textHierarchy)
    }
}

extension AnyShapeStyle {
    /// A semantic role when a condition holds, otherwise the emphasis level —
    /// the shape almost every card header takes, and the only way to put a
    /// `Color` and a `HierarchicalShapeStyle` in one ternary.
    static func role(_ role: Color, when condition: Bool, otherwise emphasis: Emphasis) -> AnyShapeStyle {
        condition ? AnyShapeStyle(role) : AnyShapeStyle(emphasis.textHierarchy)
    }
}

extension View {
    /// Sets this view's foreground to the semantic style for `emphasis`.
    ///
    /// Text only. For a fill or a border use `Color.chatSurface(_:colorScheme:)`
    /// or `Color.emphasized(_:colorScheme:)`, which carry real alpha.
    func emphasis(_ emphasis: Emphasis) -> some View {
        modifier(EmphasisModifier(emphasis: emphasis))
    }
}
