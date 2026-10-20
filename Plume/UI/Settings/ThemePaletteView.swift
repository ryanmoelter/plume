import GhosttyTheme
import SwiftUI

/// One terminal theme's palette on its own background: the regular colors
/// over their bright variants, the text color, then the system accent. Every
/// swatch but the text color picks the accent color; nil is the system accent.
struct ThemePaletteView: View {
    let definition: GhosttyThemeDefinition
    /// Disambiguates swatches for the control server when a pair shows two
    /// palettes.
    let label: String
    let selectedSlot: Int?
    let onSelect: (Int?) -> Void

    private var foreground: Color { Color(hex: definition.foreground) ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(definition.name)
                .font(.subheadline)
                .foregroundStyle(foreground.opacity(0.7))
            HStack(alignment: .center, spacing: 14) {
                PaletteSwatchGrid(
                    colors: SidebarTint.paletteSlots.map { definition.palette[$0].flatMap(Color.init(hex:)) },
                    ringColor: foreground,
                    selectedSlot: selectedSlot,
                    plumeID: AccessibilityID.settingsAccentSwatch,
                    plumeLabel: label,
                    onSelect: { onSelect($0) }
                )
                captioned("Text") {
                    Circle()
                        .fill(foreground)
                        .frame(width: PaletteSwatchGrid.swatchSize, height: PaletteSwatchGrid.swatchSize)
                }
                captioned("System") {
                    PaletteSwatch(
                        color: Color(nsColor: .controlAccentColor),
                        ringColor: foreground,
                        isSelected: selectedSlot == nil,
                        help: "The system accent color",
                        plumeID: AccessibilityID.settingsAccentSwatch,
                        plumeLabel: "\(label) system",
                        select: { onSelect(nil) }
                    )
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

    private func captioned(_ caption: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(caption)
                .font(.caption.weight(.regular))
                .foregroundStyle(foreground.opacity(0.7))
        }
    }
}
