import AppKit
import GhosttyTheme
import SwiftUI

/// Tints Plume's own chrome with the user's resolved terminal theme, so the
/// window reads as one surface instead of a terminal pane bolted onto default
/// macOS controls.
///
/// Covers the sidebar, the tab strip and the chat — including the plan view's
/// glass tint, so a document reads as the chat holding it. Sheets, Settings
/// and the archive view stay standard chrome.
enum ThemeChrome {
    /// Background tint for the given color scheme, or nil to fall back to
    /// default chrome — no theme configured, or its color didn't parse.
    static func background(for colorScheme: ColorScheme) -> Color? {
        background(for: colorScheme, in: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    /// Foreground color for the given color scheme, for text/icons drawn
    /// directly on the tinted background.
    static func foreground(for colorScheme: ColorScheme) -> Color? {
        foreground(for: colorScheme, in: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    /// Testable core: picks the definition for `colorScheme` out of an
    /// explicit `ResolvedDefinitions` rather than reading the live runtime.
    static func background(
        for colorScheme: ColorScheme,
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> Color? {
        definition(for: colorScheme, in: definitions).flatMap { Color(hex: $0.background) }
    }

    static func foreground(
        for colorScheme: ColorScheme,
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> Color? {
        definition(for: colorScheme, in: definitions).flatMap { Color(hex: $0.foreground) }
    }

    private static func definition(
        for colorScheme: ColorScheme,
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> GhosttyThemeDefinition? {
        switch colorScheme {
        case .light: return definitions?.light
        case .dark: return definitions?.dark
        @unknown default: return definitions?.dark
        }
    }

    /// The ANSI palette slots Plume draws status accents from.
    ///
    /// Each role names both variants: the normal slot is the accent, and the
    /// bright one stands in when a theme omits it or sets one that vanishes
    /// into its own background.
    enum PaletteAccent {
        case danger
        case success
        case warning
        case attention
        /// A pull request that landed. Its own hue because merged is neither
        /// good news nor bad — it is the end of the story.
        case merged

        var normalSlot: Int {
            switch self {
            case .danger: return 1
            case .success: return 2
            case .warning: return 3
            case .attention: return 4
            case .merged: return 5
            }
        }

        var brightSlot: Int { normalSlot + 8 }
    }

    /// A status accent drawn from the terminal palette, or nil to fall back to
    /// a system color — no theme, no such slot, or an unparseable hex.
    static func paletteAccent(_ accent: PaletteAccent, for colorScheme: ColorScheme) -> Color? {
        paletteAccent(accent, for: colorScheme, in: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    static func dangerAccent(for colorScheme: ColorScheme) -> Color? {
        paletteAccent(.danger, for: colorScheme)
    }

    static func successAccent(for colorScheme: ColorScheme) -> Color? {
        paletteAccent(.success, for: colorScheme)
    }

    static func warningAccent(for colorScheme: ColorScheme) -> Color? {
        paletteAccent(.warning, for: colorScheme)
    }

    static func attentionAccent(for colorScheme: ColorScheme) -> Color? {
        paletteAccent(.attention, for: colorScheme)
    }

    static func mergedAccent(for colorScheme: ColorScheme) -> Color? {
        paletteAccent(.merged, for: colorScheme)
    }

    /// Testable core: reads an explicit `ResolvedDefinitions` rather than the
    /// live runtime.
    ///
    /// Takes the normal slot in either appearance, falling through to the
    /// bright one only when the theme leaves it out.
    static func paletteAccent(
        _ accent: PaletteAccent,
        for colorScheme: ColorScheme,
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> Color? {
        guard let definition = definition(for: colorScheme, in: definitions) else { return nil }

        // The same slot in either appearance: a role that swapped slots
        // between light and dark would change hue when the system does, and
        // the two themes already carry their own palettes. A low-contrast
        // palette is the user's own choice, so it is used as written.
        let accent = [accent.normalSlot, accent.brightSlot]
            .lazy
            .compactMap { definition.palette[$0].flatMap(Color.init(hex:)) }
            .first
        return accent
    }

    /// Background tint for the window and its titlebar, or nil to leave them
    /// at their default system color.
    ///
    /// Resolves per draw rather than per call, so a light/dark switch recolors
    /// the titlebar and the window edges without anything having to re-set it.
    static func titlebarBackground() -> NSColor? {
        titlebarBackground(in: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    static func titlebarBackground(
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> NSColor? {
        let light = background(for: .light, in: definitions)
        let dark = background(for: .dark, in: definitions)
        guard let light, let dark else { return nil }

        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        }
    }
}

private struct ThemeTintModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let background = ThemeChrome.background(for: colorScheme)
        let foreground = ThemeChrome.foreground(for: colorScheme)
        content
            // Left visible so `List`'s vibrant sidebar material still shows
            // through the tint below — an opaque `.background()` here would
            // paint over the system glass instead of tinting it, the same
            // way the composer's own glass panel tints rather than covers.
            .scrollContentBackground(.visible)
            .background(background?.opacity(0.5) ?? Color.clear)
            .foregroundStyle(background == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(foreground ?? .primary))
    }
}

extension View {
    /// Tints this view with the resolved terminal theme's background, over
    /// its existing material rather than in place of it. Falls back to
    /// standard chrome when no theme is configured or its color didn't parse.
    func themeTint(colorScheme: ColorScheme) -> some View {
        modifier(ThemeTintModifier(colorScheme: colorScheme))
    }
}
