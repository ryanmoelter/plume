import SwiftUI

/// A Linear workflow state as a symbol, in the theme color nearest the
/// state's own.
struct LinearIssueGlyph: View, ThemedView {
    @Environment(\.theme) var theme

    let stateType: LinearStateType
    /// A `#rrggbb` hex string. An unparseable or gray one draws in the text
    /// color.
    let colorHex: String?

    var body: some View {
        let image = Image(systemName: Self.symbolName(for: stateType))
        if let color {
            image.foregroundStyle(color)
        } else {
            image.emphasis(.secondary)
        }
    }

    private var color: Color? {
        guard let rgb = colorHex.flatMap(HexRGB.init(hex:)) else { return nil }
        var candidates: [Int: HexRGB] = [:]
        for slot in LinearStateColor.slots {
            candidates[slot] = colors.rgb(forSlot: slot) ?? LinearStateColor.fallbackSlots[slot]
        }
        guard let slot = LinearStateColor.nearestSlot(to: rgb, among: candidates) else { return nil }
        if let themed = colors.color(forSlot: slot) { return themed }
        return candidates[slot].map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    static func symbolName(for stateType: LinearStateType) -> String {
        switch stateType {
        case .backlog: "circle.dashed"
        case .unstarted: "circle"
        case .started: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .canceled: "xmark.circle.fill"
        case .triage: "circle.dotted"
        case .other: "circle"
        }
    }
}
