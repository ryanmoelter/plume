import Testing
import Foundation
import SwiftData
@testable import Plume

/// `SidebarTint` round-trips through its raw string, rejects anything else as
/// nil, and resolves a task's color as its own over its group's.
@MainActor
struct SidebarTintTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test(arguments: [SidebarTint.text, .palette(slot: 0), .palette(slot: 9), .palette(slot: 15)])
    func rawValueRoundTrips(_ tint: SidebarTint) {
        #expect(SidebarTint(rawValue: tint.rawValue) == tint)
    }

    @Test(arguments: ["", "Text", "palette:", "palette:x", "palette:-1", "palette:16", "red"])
    func unrecognizedRawValueIsNil(_ raw: String) {
        #expect(SidebarTint(rawValue: raw) == nil)
    }

    @Test func modelAccessorsWriteRawValues() throws {
        let context = ModelContext(try container())
        let group = TaskStore.createGroup(in: context, name: "Group", existing: [])
        group.tint = .palette(slot: 4)
        #expect(group.tintRaw == "palette:4")
        group.tint = nil
        #expect(group.tintRaw == nil)

        let task = TaskStore.createTask(in: context, siblings: [])
        task.tintRaw = "palette:99"
        #expect(task.tint == nil)
    }

    @Test func taskInheritsItsGroupsTint() throws {
        let context = ModelContext(try container())
        let group = TaskStore.createGroup(in: context, name: "Group", existing: [])
        group.tint = .palette(slot: 2)
        let task = TaskStore.createTask(in: context, group: group, siblings: [])

        #expect(SidebarTint.effective(for: task) == .palette(slot: 2))
    }

    @Test func taskTintOverridesItsGroups() throws {
        let context = ModelContext(try container())
        let group = TaskStore.createGroup(in: context, name: "Group", existing: [])
        group.tint = .palette(slot: 2)
        let task = TaskStore.createTask(in: context, group: group, siblings: [])
        task.tint = .text

        #expect(SidebarTint.effective(for: task) == .text)
    }

    @Test func ungroupedTaskWithoutTintHasNone() throws {
        let context = ModelContext(try container())
        let task = TaskStore.createTask(in: context, siblings: [])

        #expect(SidebarTint.effective(for: task) == nil)
    }
}
