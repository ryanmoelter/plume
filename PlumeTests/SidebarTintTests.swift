import Testing
import Foundation
import SwiftData
import SwiftUI
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

/// A task's icon is tinted under a Dot marker or colored names, and the recent
/// list is deduplicated, capped, most recent first and custom-only.
struct SidebarIconsTests {
    private let tint = SidebarTint.palette(slot: 3)

    @Test(arguments: [
        (SidebarTaskMarker.dot, false, true),
        (.dot, true, true),
        (.bar, true, true),
        (.none, true, true),
        (.bar, false, false),
        (.none, false, false),
    ])
    func taskIconTintRule(marker: SidebarTaskMarker, colorsNames: Bool, tinted: Bool) {
        let result = SidebarIcons.taskTint(effective: tint, marker: marker, colorsNames: colorsNames)
        #expect(result == (tinted ? tint : nil))
    }

    @Test func taskIconWithoutColorHasNoTint() {
        #expect(SidebarIcons.taskTint(effective: nil, marker: .dot, colorsNames: true) == nil)
    }

    @Test func taskWeightFollowsBoldSetting() {
        #expect(SidebarIcons.taskWeight(bold: true) == .bold)
        #expect(SidebarIcons.taskWeight(bold: false) == .regular)
    }

    @Test func recordingPutsNewestFirst() {
        #expect(SidebarIcons.recording("moon", in: ["sun", "cloud"]) == ["moon", "sun", "cloud"])
    }

    @Test func recordingDeduplicatesByMovingToFront() {
        #expect(SidebarIcons.recording("cloud", in: ["sun", "cloud", "moon"]) == ["cloud", "sun", "moon"])
    }

    @Test func recordingCapsAtTwelve() {
        let recent = (0..<12).map { "custom.\($0)" }
        let result = SidebarIcons.recording("new", in: recent)
        #expect(result.count == 12)
        #expect(result.first == "new")
        #expect(!result.contains("custom.11"))
    }

    @Test func recordingIgnoresCuratedAndNil() {
        #expect(SidebarIcons.recording("star", in: ["sun"]) == ["sun"])
        #expect(SidebarIcons.recording(nil, in: ["sun"]) == ["sun"])
    }
}
