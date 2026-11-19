import SwiftUI
#if DEBUG
import SwiftData

/// Names a task by ID, or by a substring of its title.
nonisolated struct SidebarRevealParams: Decodable, Equatable {
    var task: String?
}

nonisolated struct SidebarRevealResult: Encodable, Equatable {
    let taskID: UUID
}

/// A request for the sidebar to scroll a task's row into view. Serial so
/// asking twice for one task scrolls twice.
@MainActor
@Observable
final class SidebarRevealRequests {
    static let shared = SidebarRevealRequests()

    struct Request: Equatable {
        let taskID: UUID
        let serial: Int
    }

    private(set) var latest: Request?

    func reveal(_ taskID: UUID) {
        latest = Request(taskID: taskID, serial: (latest?.serial ?? 0) + 1)
    }
}

/// `sidebar.reveal`: the sidebar is lazy, so a row below the fold registers
/// no controls, and a hidden instance can take no scroll gesture or key.
@MainActor
enum ControlSidebarCommands {
    static func reveal(
        _ params: SidebarRevealParams,
        in context: ModelContext,
        requests: SidebarRevealRequests = .shared
    ) throws -> SidebarRevealResult {
        guard let name = params.task else { throw ControlError.badParams("sidebar.reveal needs task") }
        let task = try ControlTabCommands.task(name, among: try ControlTabCommands.liveTasks(in: context))
        if let group = task.group, !group.isExpanded {
            throw ControlError.unsupported("task \"\(name)\" is in the collapsed group \"\(group.name)\"")
        }
        requests.reveal(task.id)
        return SidebarRevealResult(taskID: task.id)
    }
}

extension View {
    /// Scrolls to the row `sidebar.reveal` asked for. Unanimated, so the row
    /// is in place by the next layout pass.
    func controlSidebarReveal<ID: Hashable>(proxy: ScrollViewProxy, rowID: @escaping (UUID) -> ID?) -> some View {
        onChange(of: SidebarRevealRequests.shared.latest) { _, request in
            guard let request, let id = rowID(request.taskID) else { return }
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
#else
extension View {
    func controlSidebarReveal<ID: Hashable>(proxy: ScrollViewProxy, rowID: @escaping (UUID) -> ID?) -> some View {
        self
    }
}
#endif
