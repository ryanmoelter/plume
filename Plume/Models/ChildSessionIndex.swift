import Foundation
import Observation
import SwiftData

/// The tabs sessions started, by parent id, and those parents by their own
/// id, so finding a tab's relations in other tasks reads no store.
/// `TaskStore.addChildTab` records each child as it opens, and `rebuild`
/// reads the store once at launch. An entry can outlive its tab's task or
/// pane, so readers filter for open tabs.
@MainActor @Observable
final class ChildSessionIndex {
    static let shared = ChildSessionIndex()

    private var childrenByParent: [UUID: [TaskTab]] = [:]
    private var parentsByID: [UUID: TaskTab] = [:]

    func record(child: TaskTab, parent: TaskTab) {
        parentsByID[parent.id] = parent
        if childrenByParent[parent.id]?.contains(where: { $0 === child }) != true {
            childrenByParent[parent.id, default: []].append(child)
        }
    }

    func children(of parentID: UUID) -> [TaskTab] {
        childrenByParent[parentID] ?? []
    }

    func parent(_ id: UUID) -> TaskTab? {
        parentsByID[id]
    }

    /// Drops a tab that is being deleted.
    func forget(_ tab: TaskTab) {
        parentsByID[tab.id] = nil
        childrenByParent[tab.id] = nil
        if let parentID = tab.parentTabID {
            childrenByParent[parentID]?.removeAll { $0 === tab }
        }
    }

    func rebuild(in context: ModelContext) {
        let tabs = (try? context.fetch(FetchDescriptor<TaskTab>())) ?? []
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in tabs {
            guard let parentID = tab.parentTabID, parentID != tab.id, let parent = byID[parentID] else { continue }
            record(child: tab, parent: parent)
        }
    }
}
