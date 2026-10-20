import Testing
import Foundation
import SwiftData
import AppKit
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

    @Test func movedTaskTakesItsNewGroupsTint() throws {
        let context = ModelContext(try container())
        let source = TaskStore.createGroup(in: context, name: "Source", existing: [])
        source.tint = .palette(slot: 2)
        let destination = TaskStore.createGroup(in: context, name: "Destination", existing: [source])
        destination.tint = .palette(slot: 5)
        let task = TaskStore.createTask(in: context, group: source, siblings: [])

        TaskStore.move(task, to: destination, siblings: [])
        #expect(SidebarTint.effective(for: task) == .palette(slot: 5))

        TaskStore.move(task, to: nil, siblings: [])
        #expect(SidebarTint.effective(for: task) == nil)
    }
}

/// The resolver puts the bar under the color bar setting, the icon under the
/// icon setting, and the title under colored names only.
struct SidebarTaskAppearanceTests {
    private let tint = SidebarTint.palette(slot: 3)

    private func appearance(
        showsBar: Bool = true,
        colorsNames: Bool = false,
        colorsIcons: Bool = true,
        bold: Bool = false,
        effective: SidebarTint? = SidebarTint.palette(slot: 3)
    ) -> SidebarTaskAppearance {
        SidebarTaskAppearance(
            effective: effective, showsBar: showsBar, colorsNames: colorsNames, colorsIcons: colorsIcons, bold: bold
        )
    }

    @Test(arguments: [false, true])
    func iconTintFollowsSettingAlone(colorsNames: Bool) {
        #expect(appearance(colorsNames: colorsNames, colorsIcons: true).iconTint == tint)
        #expect(appearance(colorsNames: colorsNames, colorsIcons: false).iconTint == nil)
    }

    @Test func barTintFollowsSettingAlone() {
        #expect(appearance(showsBar: true).barTint == tint)
        #expect(appearance(showsBar: false).barTint == nil)
    }

    @Test func titleTintOnlyWithColoredNames() {
        #expect(appearance(colorsNames: true).titleTint == tint)
        #expect(appearance(colorsNames: false).titleTint == nil)
    }

    @Test func uncoloredTaskHasNoTints() {
        let result = appearance(colorsNames: true, colorsIcons: true, effective: nil)
        #expect(result.barTint == nil)
        #expect(result.iconTint == nil)
        #expect(result.titleTint == nil)
    }

    @Test func weightFollowsBold() {
        #expect(appearance(bold: true).weight == .bold)
        #expect(appearance(bold: false).weight == .regular)
    }
}

/// The recent list is deduplicated, capped, most recent first and custom-only.
struct SidebarIconsTests {
    @Test func renderingModeIsExplicitForBothSettings() {
        let describe = { (mode: SymbolRenderingMode) in String(describing: mode) }
        #expect(describe(SidebarIcons.renderingMode(twoTone: true)) == describe(.hierarchical))
        #expect(describe(SidebarIcons.renderingMode(twoTone: false)) == describe(.monochrome))
        #expect(describe(.hierarchical) != describe(.monochrome))
    }

    @Test func filledVariantFallsBackWhenThereIsNone() {
        #expect(SidebarIcons.filledVariant(of: "person.2") == "person.2.fill")
        #expect(SidebarIcons.filledVariant(of: "server.rack") == "server.rack")
    }

    @Test func previewTintStandsInForTheSystemAccent() {
        #expect(SidebarPreviewTint.effective(accentSlot: nil) == .text)
        #expect(SidebarPreviewTint.effective(accentSlot: 4) == .palette(slot: 4))
    }

    @Test func recordingPutsNewestFirst() {
        #expect(SidebarIcons.recording("moon", in: ["sun", "cloud"]) == ["moon", "sun", "cloud"])
    }

    @Test func recordingDeduplicatesByMovingToFront() {
        #expect(SidebarIcons.recording("rain", in: ["sun", "rain", "moon"]) == ["rain", "sun", "moon"])
    }

    @Test func recordingCapsAtThePopularCount() {
        let limit = SidebarIcons.popular.count
        #expect(SidebarIcons.recentLimit == limit)
        let recent = (0..<limit).map { "custom.\($0)" }
        let result = SidebarIcons.recording("new", in: recent)
        #expect(result.count == limit)
        #expect(result.first == "new")
        #expect(!result.contains("custom.\(limit - 1)"))
    }

    @Test func recordingIgnoresPopularAndNil() {
        #expect(SidebarIcons.recording("star", in: ["sun"]) == ["sun"])
        #expect(SidebarIcons.recording(nil, in: ["sun"]) == ["sun"])
    }

    @Test func recordingIgnoresFilledPopularVariants() {
        #expect(SidebarIcons.popularFilled != SidebarIcons.popular)
        for name in SidebarIcons.popularFilled {
            #expect(SidebarIcons.recording(name, in: ["sun"]) == ["sun"], "\(name)")
        }
        #expect(SidebarIcons.recording("star.fill", in: []) == [])
    }

    @Test func popularNamesAreValidSymbolsInWholeRows() {
        for name in SidebarIcons.popular + SidebarIcons.popularFilled {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
        #expect(SidebarIcons.popular.count % SidebarIcons.columns == 0)
        #expect(SidebarIcons.popular(filled: false) == SidebarIcons.popular)
        #expect(SidebarIcons.popular(filled: true) == SidebarIcons.popularFilled)
    }
}

@MainActor
struct GroupNameSettlingTests {
    @Test func blankNameFallsBack() {
        let group = TaskGroup(name: "  \n", orderIndex: 0)
        group.settleName(fallback: "Work")
        #expect(group.name == "Work")
    }

    @Test func newGroupIsNamedNewGroup() throws {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let group = TaskStore.createGroup(in: ModelContext(container), existing: [])
        #expect(group.name == "New group")
    }

    @Test(arguments: ["", " \t\n"])
    func blankNameRevertsToNewGroup(_ blank: String) {
        let group = TaskGroup(name: blank, orderIndex: 0)
        group.settleName(fallback: TaskStore.defaultGroupName)
        #expect(group.name == "New group")
    }

    @Test func nameIsTrimmed() {
        let group = TaskGroup(name: " Work ", orderIndex: 0)
        group.settleName(fallback: "Other")
        #expect(group.name == "Work")
    }
}
