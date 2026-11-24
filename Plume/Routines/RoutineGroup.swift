import Foundation
import SwiftData

/// The sidebar group routine runs land in.
enum RoutineGroup {
    static let defaultName = "Routines"

    static func find(in context: ModelContext) -> TaskGroup? {
        let kind = TaskGroupKind.routines.rawValue
        let descriptor = FetchDescriptor<TaskGroup>(
            predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\.orderIndex)]
        )
        return (try? context.fetch(descriptor))?.first
    }

    static func findOrCreate(in context: ModelContext) -> TaskGroup {
        if let group = find(in: context) { return group }
        let existing = (try? context.fetch(FetchDescriptor<TaskGroup>())) ?? []
        let group = TaskStore.createGroup(in: context, name: defaultName, existing: existing)
        group.kind = .routines
        return group
    }
}
