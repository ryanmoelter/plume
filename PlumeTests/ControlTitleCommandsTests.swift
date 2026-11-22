import Foundation
import SwiftData
import Testing

@testable import Plume

/// `task.rename` names the task and `tab.title` retitles a tab, each changing
/// the title the sidebar shows.
@MainActor
struct ControlTitleCommandsTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    @Test func renameNamesTheMatchingTask() throws {
        let task = TaskStore.createTask(in: context, title: "Old name", siblings: [])
        try context.save()

        let result = try ControlTitleCommands.renameTask(.init(task: "old", title: "New name"), in: context)

        #expect(result == TitleResult(taskID: task.id, tabID: nil, title: "New name"))
        #expect(task.title == "New name")
    }

    @Test func tabTitleReplacesTheShownTitle() throws {
        let task = TaskStore.createTask(in: context, title: "Driven", siblings: [])
        let tab = TaskStore.addTab(to: task, kind: .agent, in: context)
        try context.save()
        TitleStore.shared.setTitle("Before", forTab: tab.id, source: .custom)

        let result = try ControlTitleCommands.setTabTitle(.init(tabID: tab.id, title: "After"), in: context)

        #expect(result == TitleResult(taskID: task.id, tabID: tab.id, title: "After"))
        #expect(TitleStore.shared.displayTitle(forTab: tab) == "After")
    }

    @Test func bothRefuseAMissingTitle() throws {
        let task = TaskStore.createTask(in: context, title: "Driven", siblings: [])
        let tab = TaskStore.addTab(to: task, kind: .agent, in: context)
        try context.save()

        #expect(throws: ControlError.self) { try ControlTitleCommands.renameTask(.init(task: "Driven"), in: context) }
        #expect(throws: ControlError.self) { try ControlTitleCommands.setTabTitle(.init(tabID: tab.id), in: context) }
    }

    @Test func theWireNamesTheCommands() throws {
        let rename = try JSONDecoder().decode(
            ControlServerRequest.self,
            from: Data(#"{"id":"1","command":"task.rename","task":"Old","title":"New"}"#.utf8)
        )
        let retitle = try JSONDecoder().decode(
            ControlServerRequest.self,
            from: Data(#"{"id":"2","command":"tab.title","label":"Chat","title":"New"}"#.utf8)
        )
        guard case .renameTask(let renameParams) = rename.command,
              case .setTabTitle(let titleParams) = retitle.command else {
            Issue.record("decoded \(rename.command), \(retitle.command)")
            return
        }
        #expect(renameParams == TaskRenameParams(task: "Old", title: "New"))
        #expect(titleParams == TabTitleParams(label: "Chat", title: "New"))
    }
}
