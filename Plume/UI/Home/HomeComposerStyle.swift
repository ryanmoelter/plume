import Foundation

/// Where Home's composer shows the destination picker. Release builds use the
/// first case; Settings ▸ Debug switches among them.
nonisolated enum HomeComposerVariant: String, CaseIterable, Sendable {
    case aboveField
    case headerStrip
    case controlRow

    static let userDefaultsKey = "homeComposerVariant"

    var title: String {
        switch self {
        case .aboveField: "D: Menus above the text"
        case .headerStrip: "E: Header strip"
        case .controlRow: "F: In the control row"
        }
    }
}

/// Where Home's composer sits. Release builds use the first case.
nonisolated enum HomeComposerPlacement: String, CaseIterable, Sendable {
    case top
    case pinnedBottom

    static let userDefaultsKey = "homeComposerPlacement"

    var title: String {
        switch self {
        case .top: "Top"
        case .pinnedBottom: "Pinned bottom"
        }
    }
}
