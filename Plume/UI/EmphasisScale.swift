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

/// Semantic color roles, resolved once so no view reaches for a literal
/// `Color.orange` or `Color.blue`.
///
/// Selection is the only role that follows the user's accent color. The rest
/// are fixed hues, because a status color that changes meaning when someone
/// picks graphite in System Settings is not a status color.
enum ChatRole {
    /// Something is waiting on the user — a stalled permission, a question.
    ///
    /// Orange, not the accent color: on macOS blue *is* selection, and a
    /// stalled agent needs to be distinguishable from the row that happens to
    /// be selected.
    static let attention = Color.orange
    /// A condition worth knowing about that is not blocking anything.
    static let warning = Color.yellow
    /// Destructive or failed.
    static let danger = Color.red
    /// Succeeded.
    static let success = Color.green
    /// The user's choice, and only that. Follows the system accent color.
    static let selection = Color.accentColor
    /// Live activity — a turn in flight. Not attention: nothing is blocked.
    static let activity = Color.blue
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
