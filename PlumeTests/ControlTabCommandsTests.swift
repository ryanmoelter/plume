import Foundation
import SwiftData
import Testing

@testable import Plume

/// `tab.move` and `tab.split` name a tab by ID or title, and a task by ID or
/// title, refusing a name that matches more than one.
@MainActor
struct ControlTabCommandsTests {
    private let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
    }

    private func save() throws { try context.save() }

    @Test func moveTakesATabToTheNamedTask() throws {
        let source = TaskStore.createTask(in: context, title: "Source", siblings: [])
        let tab = TaskStore.addTab(to: source, kind: .terminal, in: context)
        let destination = TaskStore.createTask(in: context, title: "Destination", siblings: [source])
        try save()

        let result = try ControlTabCommands.move(.init(tabID: tab.id, toTask: "destination"), in: context)

        #expect(result == TabTaskResult(tabID: tab.id, taskID: destination.id))
        #expect(tab.task?.id == destination.id)
    }

    @Test func moveRefusesAnAmbiguousTask() throws {
        let source = TaskStore.createTask(in: context, title: "Source", siblings: [])
        let tab = TaskStore.addTab(to: source, kind: .terminal, in: context)
        let one = TaskStore.createTask(in: context, title: "Other one", siblings: [source])
        _ = TaskStore.createTask(in: context, title: "Other two", siblings: [source, one])
        try save()

        #expect(throws: ControlError.self) {
            try ControlTabCommands.move(.init(tabID: tab.id, toTask: "other"), in: context)
        }
        #expect(tab.task?.id == source.id)
    }

    @Test func splitPutsTheTabInANewTask() throws {
        let source = TaskStore.createTask(in: context, title: "Source", siblings: [])
        let tab = TaskStore.addTab(to: source, kind: .terminal, in: context)
        try save()

        let result = try ControlTabCommands.split(.init(tabID: tab.id), in: context)

        #expect(result.taskID != source.id)
        #expect(tab.task?.id == result.taskID)
    }

    @Test func theWireNamesBothCommands() throws {
        let move = try JSONDecoder().decode(
            ControlServerRequest.self,
            from: Data(#"{"id":"1","command":"tab.move","label":"Chat","toTask":"Other"}"#.utf8)
        )
        guard case .moveTab(let params) = move.command else {
            Issue.record("decoded \(move.command)")
            return
        }
        #expect(params == TabMoveParams(label: "Chat", toTask: "Other"))
        let split = try JSONDecoder().decode(
            ControlServerRequest.self, from: Data(#"{"id":"2","command":"tab.split","label":"Chat"}"#.utf8)
        )
        guard case .splitTab = split.command else {
            Issue.record("decoded \(split.command)")
            return
        }
    }
}
