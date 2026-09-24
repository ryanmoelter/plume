import Foundation

/// Codex's collaboration mode is independent of its permission profile.
enum CodexCollaborationMode: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case plan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "Code"
        case .plan: "Plan"
        }
    }
}
