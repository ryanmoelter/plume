import Testing
import Foundation
import SwiftData
@testable import Plume

@MainActor
private final class FakeTitleModel: TaskTitleModel {
    var isAvailable = true
    var reply: Result<String, Error> = .success("Shared work")
    private(set) var calls: [[String]] = []

    func summarize(chatTitles: [String]) async throws -> String {
        calls.append(chatTitles)
        return try reply.get()
    }
}

private struct ModelFailure: Error {}

/// A task with several top-level chats takes a summary of their titles; one
/// chat, the setting off, or no model leaves it on its last-focused chat.
@MainActor
struct TaskTitleSummarizerTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Schema([TaskGroup.self, WorkTask.self, TaskTab.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    private func twoChatTask(in context: ModelContext, titles: TitleStore) -> (WorkTask, TaskTab, TaskTab) {
        let task = TaskStore.createTask(in: context, siblings: [])
        let first = task.tabs[0]
        let second = TaskStore.addTab(to: task, kind: .agent, in: context)
        titles.setTitle("Fix login", forTab: first.id, source: .reply)
        titles.setTitle("Add logout", forTab: second.id, source: .reply)
        return (task, first, second)
    }

    @Test func aTaskWithSeveralChatsTakesTheirSummary() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)

        #expect(store.displayTitle(for: task) == "Add logout")
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Shared work")
        #expect(model.calls == [["Add logout", "Fix login"]])
    }

    @Test func aNamedTaskKeepsItsNameOverASummary() async throws {
        let context = try makeContext()
        let summarizer = TaskTitleSummarizer(model: FakeTitleModel(), isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)
        task.title = "Auth"
        _ = store.generatedTitle(for: task)
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Auth")
    }

    @Test func aTaskWithOneChatIsNeverSummarized() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let task = TaskStore.createTask(in: context, siblings: [])
        store.setTitle("Fix login", forTab: task.tabs[0].id, source: .reply)
        _ = store.displayTitle(for: task)
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Fix login")
        #expect(model.calls.isEmpty)
    }

    @Test func turningTheSettingOffFallsBackToTheLastFocusedChat() async throws {
        let context = try makeContext()
        var enabled = true
        let summarizer = TaskTitleSummarizer(model: FakeTitleModel(), isEnabled: { enabled })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)
        _ = store.displayTitle(for: task)
        await summarizer.idle()

        enabled = false
        #expect(store.displayTitle(for: task) == "Add logout")
    }

    @Test func anUnavailableModelFallsBackWithoutAsking() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        model.isAvailable = false
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)
        _ = store.displayTitle(for: task)
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Add logout")
        #expect(model.calls.isEmpty)
    }

    @Test func aFailedSummaryFallsBackAndIsNotRetriedForTheSameTitles() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        model.reply = .failure(ModelFailure())
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)
        _ = store.displayTitle(for: task)
        await summarizer.idle()
        _ = store.displayTitle(for: task)
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Add logout")
        #expect(model.calls.count == 1)
    }

    @Test func aRetitledChatKeepsTheOldSummaryUntilTheNewOneArrives() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, first, _) = twoChatTask(in: context, titles: store)
        _ = store.displayTitle(for: task)
        await summarizer.idle()

        model.reply = .success("Session handling")
        store.setTitle("Refresh tokens", forTab: first.id, source: .reply)
        #expect(store.displayTitle(for: task) == "Shared work")
        await summarizer.idle()

        #expect(store.displayTitle(for: task) == "Session handling")
        #expect(model.calls.count == 2)
    }

    @Test func repeatedReadsAskTheModelOnce() async throws {
        let context = try makeContext()
        let model = FakeTitleModel()
        let summarizer = TaskTitleSummarizer(model: model, isEnabled: { true })
        let store = TitleStore(summarizer: summarizer)
        let (task, _, _) = twoChatTask(in: context, titles: store)
        for _ in 0..<5 { _ = store.displayTitle(for: task) }
        await summarizer.idle()
        for _ in 0..<5 { _ = store.displayTitle(for: task) }

        #expect(model.calls.count == 1)
    }

    @Test(arguments: [
        ("Auth flow", "Auth flow"),
        ("\"Auth flow.\"", "Auth flow"),
        ("Title: Auth flow", "Auth flow"),
        ("\n  Auth flow\nBecause both chats…", "Auth flow"),
        ("  ", nil),
    ] as [(String, String?)])
    func aReplyIsCleanedToOneLine(reply: String, expected: String?) {
        #expect(TaskTitleSummarizer.cleaned(reply) == expected)
    }

    @Test func aLongReplyIsTruncated() throws {
        let cleaned = try #require(TaskTitleSummarizer.cleaned(String(repeating: "word ", count: 30)))
        #expect(cleaned.count <= 61)
        #expect(cleaned.hasSuffix("…"))
    }
}
