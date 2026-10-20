import SwiftUI

/// A terminal palette's 16 slots as clickable swatches: the regular colors
/// over their bright variants.
struct PaletteSwatchGrid: View {
    /// Indexed by slot; nil where the theme has no color, which draws an
    /// empty, disabled swatch.
    let colors: [Color?]
    /// Draws the selection ring and empty swatches, so it must show against
    /// whatever the grid sits on.
    let ringColor: Color
    let selectedSlot: Int?
    let plumeID: String
    /// Prefixed to each swatch's slot number for the control server.
    let plumeLabel: String
    let onSelect: (Int) -> Void

    static let swatchSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 6) {
            let slots = ThemeChrome.paletteSlots
            let middle = slots.lowerBound + slots.count / 2
            row(slots: slots.lowerBound..<middle)
            row(slots: middle..<slots.upperBound)
        }
    }

    private func row(slots: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(slots, id: \.self) { slot in
                let color = colors.indices.contains(slot) ? colors[slot] : nil
                PaletteSwatch(
                    color: color,
                    ringColor: ringColor,
                    isSelected: slot == selectedSlot,
                    help: "\(ThemeChrome.paletteSlotNames[slot]) (\(slot))",
                    plumeID: plumeID,
                    plumeLabel: "\(plumeLabel) \(slot)",
                    select: { onSelect(slot) }
                )
                .disabled(color == nil)
            }
        }
    }
}

/// One round color swatch that selects something when clicked.
struct PaletteSwatch<Content: View>: View {
    let color: Color?
    let ringColor: Color
    let isSelected: Bool
    let help: String
    let plumeID: String
    let plumeLabel: String
    let select: () -> Void
    /// Drawn over the fill, as a "None" swatch's slash is.
    @ViewBuilder var overlay: () -> Content

    var body: some View {
        Button(action: select) {
            ZStack {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(ringColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                overlay()
                if isSelected {
                    Circle()
                        .strokeBorder(ringColor, lineWidth: 2)
                        .padding(-4)
                }
            }
            .frame(width: PaletteSwatchGrid.swatchSize, height: PaletteSwatchGrid.swatchSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .plumeID(
            plumeID,
            label: plumeLabel,
            value: isSelected ? "selected" : nil,
            invoke: select
        )
    }
}

extension PaletteSwatch where Content == EmptyView {
    init(
        color: Color?,
        ringColor: Color,
        isSelected: Bool,
        help: String,
        plumeID: String,
        plumeLabel: String,
        select: @escaping () -> Void
    ) {
        self.init(
            color: color,
            ringColor: ringColor,
            isSelected: isSelected,
            help: help,
            plumeID: plumeID,
            plumeLabel: plumeLabel,
            select: select,
            overlay: { EmptyView() }
        )
    }
}
