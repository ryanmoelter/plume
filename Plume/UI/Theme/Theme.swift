import SwiftUI

/// Everything a view needs to draw itself in Plume's style.
///
/// Resolved once by `ThemeModifier` and passed down the environment, rather
/// than each view resolving colors and sizes for itself. Views reach it by
/// conforming to `ThemedView`, which gives direct `colors` / `dimensions` /
/// `typography` accessors.
struct Theme {
    var colors: Palette
    var dimensions: Dimensions
    var typography: Typography
}

private struct ThemeKey: EnvironmentKey {
    /// A theme with no terminal colors — what a preview or a view outside the
    /// themed hierarchy gets. Every color falls back to its system
    /// equivalent, which is the same thing an unthemed ghostty config yields.
    static let defaultValue = Theme(
        colors: Palette(colorScheme: .dark, definitions: nil),
        dimensions: Dimensions(bodySize: CGFloat(AppSettings.defaultChatFontSize)),
        typography: Typography(bodySize: CGFloat(AppSettings.defaultChatFontSize))
    )
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// A view drawn in Plume's style.
///
/// Conform, declare `@Environment(\.theme) var theme`, and the accessors
/// below come free — so a body reads `colors.warning` and
/// `typography.caption.mono` rather than resolving either itself.
protocol ThemedView {
    var theme: Theme { get }
}

extension ThemedView {
    var colors: Palette { theme.colors }
    var dimensions: Dimensions { theme.dimensions }
    var typography: Typography { theme.typography }

    /// The type scale in the serif, for the agent's own prose.
    ///
    /// Only the AI's voice takes it — a reply, a plan it wrote, a question it
    /// asked. Everything else, `typography` included, is the system face: what
    /// the user typed reads as input, and chrome reads as chrome.
    var proseTypography: Typography {
        theme.typography.inFace(.serif)
    }
}

/// Resolves the theme for everything below it.
///
/// The single place that reads `ColorScheme` for styling and the single
/// caller of `ThemeChrome` outside the window chrome itself. Resolving here
/// means a light/dark switch or a font-size change rebuilds the palette once,
/// instead of every color re-resolving on every `body` pass of every row.
private struct ThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let bodySize: CGFloat

    func body(content: Content) -> some View {
        let typography = Typography(bodySize: bodySize)
        let theme = Theme(
            colors: Palette(
                colorScheme: colorScheme,
                definitions: GhosttyRuntime.shared.resolvedThemeDefinitions
            ),
            dimensions: Dimensions(bodySize: bodySize),
            typography: typography
        )
        content
            .environment(\.theme, theme)
            .font(typography.body.font)
    }
}

extension View {
    /// Resolves and installs the theme for this view and its children.
    func plumeTheme(bodySize: CGFloat) -> some View {
        modifier(ThemeModifier(bodySize: bodySize))
    }
}
