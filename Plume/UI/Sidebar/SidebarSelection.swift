import Foundation

/// What the sidebar has selected: the Home overview or one task.
nonisolated enum SidebarSelection: Hashable {
    case home
    case task(UUID)

    var taskID: UUID? {
        if case .task(let id) = self { id } else { nil }
    }
}
