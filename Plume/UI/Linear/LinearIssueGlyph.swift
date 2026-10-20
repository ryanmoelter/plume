import SwiftUI

/// A Linear workflow state as a symbol, tinted with the state's own color.
struct LinearIssueGlyph: View {
    let stateType: LinearStateType
    /// A `#rrggbb` hex string. An unparseable one falls back to secondary.
    let colorHex: String?

    var body: some View {
        Image(systemName: Self.symbolName(for: stateType))
            .foregroundStyle(colorHex.flatMap { Color(hex: $0) } ?? .secondary)
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
