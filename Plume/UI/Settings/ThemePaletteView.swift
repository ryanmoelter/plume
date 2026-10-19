import GhosttyTheme
import SwiftUI

/// One terminal theme's palette on its own background: the text color on the
/// left, the regular colors over their bright variants, then the system
/// accent. Every swatch but the text color picks the accent color; nil is the
/// system accent.
struct ThemePaletteView: View {
    let definition: GhosttyThemeDefinition
    /// Disambiguates swatches for the control server when a pair shows two
    /// palettes.
    let label: String
    let selectedSlot: Int?
    let onSelect: (Int?) -> Void

    private static let swatchSize: CGFloat = 22

    private var foreground: Color { Color(hex: definition.foreground) ?? .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(definition.name)
                .font(.subheadline)
                .foregroundStyle(foreground.opacity(0.7))
            HStack(alignment: .top, spacing: 14) {
                captioned("Text") {
                    Circle()
                        .fill(foreground)
                        .frame(width: Self.swatchSize, height: Self.swatchSize)
                }
                VStack(spacing: 6) {
                    swatchRow(slots: 0..<8)
                    swatchRow(slots: 8..<16)
                }
                captioned("System") {
                    swatch(
                        color: Color(nsColor: .controlAccentColor),
                        isSelected: selectedSlot == nil,
                        help: "The system accent color",
                        id: "system",
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
        VStack(spacing: 4) {
            swatch()
            Text(caption)
                .font(.caption2.weight(.regular))
                .foregroundStyle(foreground.opacity(0.7))
        }
    }

    private func swatchRow(slots: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(slots, id: \.self) { slot in
                swatch(
                    color: definition.palette[slot].flatMap(Color.init(hex:)),
                    isSelected: slot == selectedSlot,
                    help: "\(ThemeChrome.paletteSlotNames[slot]) (\(slot))",
                    id: "\(slot)",
                    select: { onSelect(slot) }
                )
            }
        }
    }

    private func swatch(
        color: Color?,
        isSelected: Bool,
        help: String,
        id: String,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            ZStack {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(foreground.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if isSelected {
                    // Drawn in the theme's foreground, which shows against its
                    // own background whatever the swatch's hue.
                    Circle()
                        .strokeBorder(foreground, lineWidth: 2)
                        .padding(-4)
                }
            }
            .frame(width: Self.swatchSize, height: Self.swatchSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .plumeID(
            AccessibilityID.settingsAccentSwatch,
            label: "\(label) \(id)",
            value: isSelected ? "selected" : nil,
            invoke: select
        )
        .disabled(color == nil)
    }
}
