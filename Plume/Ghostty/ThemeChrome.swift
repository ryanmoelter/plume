import AppKit
import GhosttyTheme
import SwiftUI

/// Tints Plume's own chrome (sidebar, tab strip) with the user's resolved
/// terminal theme, so the window reads as one surface instead of a terminal
/// pane bolted onto default macOS controls.
///
/// Scoped deliberately to the sidebar and tab strip — sheets, Settings, and
/// the archive view stay standard chrome.
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

    /// Background tint for a titlebar in the given appearance's dark/light
    /// mode, or nil to leave the titlebar at its default system color.
    static func titlebarBackground(forDark isDark: Bool) -> NSColor? {
        titlebarBackground(forDark: isDark, in: GhosttyRuntime.shared.resolvedThemeDefinitions)
    }

    static func titlebarBackground(
        forDark isDark: Bool,
        in definitions: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> NSColor? {
        background(for: isDark ? .dark : .light, in: definitions).map(NSColor.init)
    }
}

private struct ThemeTintModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let background = ThemeChrome.background(for: colorScheme)
        let foreground = ThemeChrome.foreground(for: colorScheme)
        content
            // `List` paints its own background under `.sidebar` style; hide it
            // so the tint underneath (or default chrome, absent a theme) shows.
            .scrollContentBackground(background == nil ? .visible : .hidden)
            .background(background ?? Color.clear)
            .foregroundStyle(background == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(foreground ?? .primary))
    }
}

extension View {
    /// Applies the resolved terminal theme's background as this view's
    /// background, falling back to standard chrome when no theme is
    /// configured or its color didn't parse.
    func themeTint(colorScheme: ColorScheme) -> some View {
        modifier(ThemeTintModifier(colorScheme: colorScheme))
    }
}
