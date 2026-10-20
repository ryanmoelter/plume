import Foundation
import SwiftData

@Model
final class TaskGroup {
    var id: UUID = UUID()
    var name: String = ""
    var orderIndex: Int = 0
    var isExpanded: Bool = true
    /// A `SidebarTint` raw value; nil draws the group uncolored.
    var colorRaw: String? = nil
    /// An SF Symbol name.
    var iconName: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \WorkTask.group)
    var tasks: [WorkTask] = []

    init(name: String, orderIndex: Int) {
        self.id = UUID()
        self.name = name
        self.orderIndex = orderIndex
        self.isExpanded = true
    }

    var tint: SidebarTint? {
        get { colorRaw.flatMap(SidebarTint.init(rawValue:)) }
        set { colorRaw = newValue?.rawValue }
    }
}
