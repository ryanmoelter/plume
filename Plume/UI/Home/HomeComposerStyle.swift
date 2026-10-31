import Foundation

/// How Home's composer shows the destination picker. Release builds use the
/// first case; Settings ▸ Debug switches among them.
nonisolated enum HomeComposerVariant: String, CaseIterable, Sendable {
    case chipRow
    case destinationChip
    case breadcrumb

    static let userDefaultsKey = "homeComposerVariant"

    var title: String {
        switch self {
        case .chipRow: "A: Chip row"
        case .destinationChip: "B: One destination chip"
        case .breadcrumb: "C: Breadcrumb path"
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
