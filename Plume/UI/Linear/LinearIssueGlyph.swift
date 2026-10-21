import SwiftUI

/// A Linear workflow state as a symbol, colored by a
/// `LinearStateColorStrategy`.
struct LinearIssueGlyph: View, ThemedView {
    @Environment(\.theme) var theme

    let stateType: LinearStateType
    /// A `#rrggbb` hex string. An unparseable one, or a gray one under
    /// `.themePalette`, draws in the secondary text color.
    let colorHex: String?
    /// Nil draws Linear's color unchanged.
    let strategy: LinearStateColorStrategy?

    init(stateType: LinearStateType, colorHex: String?) {
        self.init(stateType: stateType, colorHex: colorHex, strategy: AppSettings.shared.linearStateColors)
    }

    init(stateType: LinearStateType, colorHex: String?, strategy: LinearStateColorStrategy?) {
        self.stateType = stateType
        self.colorHex = colorHex
        self.strategy = strategy
    }

    var body: some View {
        let image = Image(systemName: Self.symbolName(for: stateType))
        if let color {
            image.foregroundStyle(color)
        } else {
            image.emphasis(.secondary)
        }
    }

    private var color: Color? {
        Self.rgb(for: colorHex, strategy: strategy, in: colors).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    /// Nil means the secondary text color.
    static func rgb(for colorHex: String?, strategy: LinearStateColorStrategy?, in colors: Palette) -> HexRGB? {
        guard let rgb = colorHex.flatMap(HexRGB.init(hex:)) else { return nil }
        switch strategy {
        case nil: return rgb
        case .themePalette:
            var candidates: [Int: HexRGB] = [:]
            for slot in LinearStateColor.slots {
                candidates[slot] = colors.rgb(forSlot: slot) ?? LinearStateColor.fallbackSlots[slot]
            }
            return LinearStateColor.nearestSlot(to: rgb, among: candidates).flatMap { candidates[$0] }
        case .ensureContrast:
            return LinearStateColor.contrasted(rgb, background: colors.backgroundRGB, foreground: colors.foregroundRGB)
        }
    }

    static func symbolName(for stateType: LinearStateType) -> String {
        switch stateType {
        case .backlog: "circle.dashed"
        case .unstarted: "circle"
        case .started: "circle.righthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .canceled: "xmark.circle.fill"
        case .duplicate: "equal.circle.fill"
        case .triage: "arrow.left.and.right.circle.fill"
        case .other: "circle"
        }
    }
}
