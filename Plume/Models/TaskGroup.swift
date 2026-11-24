import Foundation
import SwiftData

@Model
final class TaskGroup {
    var id: UUID = UUID()
    var name: String = ""
    var orderIndex: Int = 0
    var isExpanded: Bool = true
    /// A `SidebarTint` raw value; nil draws the group uncolored.
    var tintRaw: String? = nil
    /// An SF Symbol name.
    var iconName: String? = nil
    /// A `TaskGroupKind` raw value.
    var kindRaw: String = TaskGroupKind.user.rawValue

    @Relationship(deleteRule: .cascade, inverse: \WorkTask.group)
    var tasks: [WorkTask] = []

    init(name: String, orderIndex: Int) {
        self.id = UUID()
        self.name = name
        self.orderIndex = orderIndex
        self.isExpanded = true
    }

    var kind: TaskGroupKind {
        get { TaskGroupKind(rawValue: kindRaw) ?? .user }
        set { kindRaw = newValue.rawValue }
    }

    var tint: SidebarTint? {
        get { tintRaw.flatMap(SidebarTint.init(rawValue:)) }
        set { tintRaw = newValue?.rawValue }
    }

    func cancelNameEdit(restoring original: String) {
        name = original
        settleName()
    }

    /// Trims the name, falling back to the default group name when that leaves it blank.
    func settleName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let settled = trimmed.isEmpty ? TaskStore.defaultGroupName : trimmed
        if settled != name { name = settled }
    }
}

/// `routines` is the group routine runs land in, found by kind so renaming
/// it keeps it.
nonisolated enum TaskGroupKind: String, Sendable {
    case user
    case routines
}

extension PersistentModel {
    /// False once the model is deleted, when writing to it can trap.
    nonisolated var isLive: Bool { modelContext != nil && !isDeleted }
}
