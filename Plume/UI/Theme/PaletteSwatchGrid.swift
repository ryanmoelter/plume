import SwiftUI

/// A terminal palette as clickable swatches. Its 16 slots are the regular
/// colors over their bright variants. The extended palette is the 12-hue
/// wheel's text colors over its bright ones, then the four neutral slots.
struct PaletteSwatchGrid: View {
    /// Nil where the theme has no color, which draws an empty, disabled swatch.
    let color: (SidebarTint) -> Color?
    /// Draws the selection ring and empty swatches, so it must show against
    /// whatever the grid sits on.
    let ringColor: Color
    let selection: SidebarTint?
    let extended: Bool
    var swatchSize: CGFloat = Self.swatchSize
    let plumeID: String
    /// Prefixed to each swatch's name for the control server.
    let plumeLabel: String
    let onSelect: (SidebarTint) -> Void

    static let swatchSize: CGFloat = 22
    /// Fits the extended palette's 12 columns in the sidebar popover.
    static let compactSwatchSize: CGFloat = 18

    private var spacing: CGFloat { swatchSize < Self.swatchSize ? 4 : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, tints in
                row(tints)
            }
        }
    }

    private var rows: [[SidebarTint]] {
        if extended {
            return [
                PaletteHue.wheel.map { SidebarTint.wheel($0, bright: false) },
                PaletteHue.wheel.map { SidebarTint.wheel($0, bright: true) },
                PaletteHue.neutralSlots.map { SidebarTint.palette(slot: $0) },
            ]
        }
        let slots = ThemeChrome.paletteSlots
        let middle = slots.lowerBound + slots.count / 2
        return [
            (slots.lowerBound..<middle).map { SidebarTint.palette(slot: $0) },
            (middle..<slots.upperBound).map { SidebarTint.palette(slot: $0) },
        ]
    }

    private func row(_ tints: [SidebarTint]) -> some View {
        HStack(spacing: spacing) {
            ForEach(tints, id: \.self) { tint in
                let color = color(tint)
                PaletteSwatch(
                    color: color,
                    ringColor: ringColor,
                    isSelected: tint == selection,
                    help: Self.help(for: tint),
                    plumeID: plumeID,
                    plumeLabel: "\(plumeLabel) \(Self.plumeName(for: tint))",
                    size: swatchSize,
                    select: { onSelect(tint) }
                )
                .disabled(color == nil)
            }
        }
    }

    private static func help(for tint: SidebarTint) -> String {
        if case .palette(let slot) = tint { "\(tint.name) (\(slot))" } else { tint.name }
    }

    /// A slot's number, or an extended hue's name prefixed `bright-` for its
    /// bright variant.
    static func plumeName(for tint: SidebarTint) -> String {
        switch tint {
        case .text: "text"
        case .palette(let slot): "\(slot)"
        case .extended(let hue, let bright): bright ? "bright-\(hue.rawValue)" : hue.rawValue
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
    var size: CGFloat = PaletteSwatchGrid.swatchSize
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
                        .padding(size < PaletteSwatchGrid.swatchSize ? -3 : -4)
                }
            }
            .frame(width: size, height: size)
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
        size: CGFloat = PaletteSwatchGrid.swatchSize,
        select: @escaping () -> Void
    ) {
        self.init(
            color: color,
            ringColor: ringColor,
            isSelected: isSelected,
            help: help,
            plumeID: plumeID,
            plumeLabel: plumeLabel,
            size: size,
            select: select,
            overlay: { EmptyView() }
        )
    }
}

/// A swatch with a caption beside it. The caption takes secondary emphasis
/// unless `captionColor` is given.
struct CaptionedSwatch<Swatch: View>: View {
    let caption: String
    var captionColor: Color?
    @ViewBuilder var swatch: () -> Swatch

    init(_ caption: String, captionColor: Color? = nil, @ViewBuilder swatch: @escaping () -> Swatch) {
        self.caption = caption
        self.captionColor = captionColor
        self.swatch = swatch
    }

    var body: some View {
        HStack(spacing: 6) {
            swatch()
            if let captionColor {
                Text(caption).font(.caption).foregroundStyle(captionColor)
            } else {
                Text(caption).font(.caption).emphasis(.secondary)
            }
        }
    }
}
