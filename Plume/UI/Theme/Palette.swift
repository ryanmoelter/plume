import SwiftUI

/// Every color Plume draws, resolved.
///
/// Built once per appearance change by `ThemeModifier`, which is the only
/// place that reads `ColorScheme` or reaches into `ThemeChrome`. Views take
/// plain `Color`s off it, so a named color costs a struct field read rather
/// than a palette lookup and a hex parse on every `body` pass. Terminal palette
/// slots are the exception: `color(forSlot:)` resolves on demand, because a
/// `Palette` is built for every chat row and most never ask for a slot.
///
/// Status hues come from the terminal theme's ANSI palette, which is what
/// makes the chat read as part of the same surface as the terminal beside it.
/// Each falls back to its system color whenever the palette can't supply one,
/// so an unthemed ghostty config looks as it did before the palette existed.
struct Palette {
    /// The window's own ground, or nil to leave default chrome showing.
    let background: Color?

    /// Text and icons drawn on `background`. Falls back to `.primary`, which
    /// carries the same meaning against default chrome.
    let foreground: Color

    /// The agent is waiting on the user and nothing is wrong — a question to
    /// answer, a reply worth reading.
    let attention: Color

    /// The agent wants to do something the user should look at first. A tool
    /// asking permission is this, not `attention`: the answer has consequences.
    let warning: Color

    /// Destructive or failed.
    let danger: Color

    /// Succeeded.
    let success: Color

    /// The user's own choice, and only that. The accent color chosen in
    /// settings, or the system accent. The text color while the window is
    /// inactive.
    let selection: Color

    /// A turn in flight. Shares `attention`'s hue because it carries the same
    /// news; the shape tells them apart — a pulsing dot while it works, a
    /// steady mark once it wants the user.
    var activity: Color { attention }

    /// Alpha levels for fills and washes, which vary by appearance.
    let emphasis: EmphasisOpacities

    private let colorScheme: ColorScheme
    private let definitions: GhosttyThemeResolver.ResolvedDefinitions?

    /// One terminal palette slot, nil where the theme has none.
    func color(forSlot slot: Int) -> Color? {
        ThemeChrome.paletteColor(slot: slot, for: colorScheme, in: definitions)
    }

    /// One terminal palette slot's components, for color math.
    func rgb(forSlot slot: Int) -> HexRGB? {
        ThemeChrome.paletteRGB(slot: slot, for: colorScheme, in: definitions)
    }

    /// A sidebar tint's color, or nil when the theme lacks its slot.
    func color(for tint: SidebarTint) -> Color? {
        switch tint {
        case .text: foreground
        case .palette(let slot): color(forSlot: slot)
        }
    }

    /// `foreground` at the given emphasis, for washes and hairlines drawn on
    /// the app's surface.
    func surface(_ level: Emphasis) -> Color {
        foreground.opacity(emphasis[level])
    }

    /// A wash separating a card from the surface behind it.
    var surfaceTint: Color { surface(.backgroundTint) }

    /// Hairlines and rule strokes.
    var divider: Color { surface(.divider) }

    /// Builds the palette for one appearance from a resolved terminal theme.
    init(
        colorScheme: ColorScheme,
        definitions: GhosttyThemeResolver.ResolvedDefinitions?,
        accentSlot: Int? = nil,
        isActive: Bool = true
    ) {
        background = ThemeChrome.background(for: colorScheme, in: definitions)
        foreground = ThemeChrome.foreground(for: colorScheme, in: definitions) ?? .primary
        attention = ThemeChrome.paletteAccent(.attention, for: colorScheme, in: definitions) ?? .blue
        warning = ThemeChrome.paletteAccent(.warning, for: colorScheme, in: definitions) ?? .orange
        danger = ThemeChrome.paletteAccent(.danger, for: colorScheme, in: definitions) ?? .red
        success = ThemeChrome.paletteAccent(.success, for: colorScheme, in: definitions) ?? .green
        selection = isActive
            ? ThemeChrome.accent(slot: accentSlot, for: colorScheme, in: definitions)
            : foreground
        emphasis = EmphasisOpacities(colorScheme: colorScheme)
        self.colorScheme = colorScheme
        self.definitions = definitions
    }
}

/// The emphasis scale's alpha values for one appearance.
///
/// Resolved up front so `Emphasis.fillOpacity(for:)` is not called with a
/// `ColorScheme` at every use site.
struct EmphasisOpacities {
    private let values: [Emphasis: Double]

    init(colorScheme: ColorScheme) {
        values = Dictionary(
            uniqueKeysWithValues: Emphasis.allCases.map { ($0, $0.fillOpacity(for: colorScheme)) }
        )
    }

    subscript(level: Emphasis) -> Double {
        values[level] ?? 1
    }
}

extension Color {
    /// This color at the given emphasis — for tinting a semantic role's own
    /// fill or border, as in an attention card's wash.
    func emphasized(_ level: Emphasis, in palette: Palette) -> Color {
        opacity(palette.emphasis[level])
    }
}
