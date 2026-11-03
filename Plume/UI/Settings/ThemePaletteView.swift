import GhosttyTheme
import SwiftUI

/// One terminal theme's palette on its own background, then the text color
/// and the system accent. Every swatch but the text color picks the accent
/// color; nil is the system accent.
struct ThemePaletteView: View {
    let definition: GhosttyThemeDefinition
    /// Disambiguates swatches for the control server when a pair shows two
    /// palettes.
    let label: String
    let selection: SidebarTint?
    let extended: Bool
    let onSelect: (SidebarTint?) -> Void

    private var foreground: Color { Color(hex: definition.foreground) ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(definition.name)
                .font(.subheadline)
                .foregroundStyle(foreground.opacity(0.7))
            // The extended grid is too wide to share a row with the captions.
            let layout = extended
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            layout {
                let colors = extended ? ExtendedPalette.Colors(definition, lum: GhosttyRuntime.bundledLumDefinitions) : nil
                PaletteSwatchGrid(
                    color: { color(for: $0, extended: colors) },
                    ringColor: foreground,
                    selection: selection,
                    extended: extended,
                    plumeID: AccessibilityID.settingsAccentSwatch,
                    plumeLabel: label,
                    onSelect: { onSelect($0) }
                )
                HStack(spacing: 14) {
                    captions
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(hex: definition.background) ?? .clear,
            in: .rect(cornerRadius: 8)
        )
    }

    private func color(for tint: SidebarTint, extended: ExtendedPalette.Colors?) -> Color? {
        ThemeChrome.tintRGB(tint, in: definition, extended: extended).map(Color.init)
    }

    @ViewBuilder
    private var captions: some View {
        CaptionedSwatch("Text", captionColor: foreground.opacity(0.7)) {
            Circle()
                .fill(foreground)
                .frame(width: PaletteSwatchGrid.swatchSize, height: PaletteSwatchGrid.swatchSize)
        }
        CaptionedSwatch("System", captionColor: foreground.opacity(0.7)) {
            PaletteSwatch(
                color: Color(nsColor: .controlAccentColor),
                ringColor: foreground,
                isSelected: selection == nil,
                help: "The system accent color",
                plumeID: AccessibilityID.settingsAccentSwatch,
                plumeLabel: "\(label) system",
                select: { onSelect(nil) }
            )
        }
    }
}
