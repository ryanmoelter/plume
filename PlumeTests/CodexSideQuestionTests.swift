import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexSideQuestionTests {
    @Test func snapshotUsesOnlyCompletedTextInConversationOrder() throws {
        let turns = [
            turn("live", status: "completed", items: [reply("Excluded live answer")]),
            turn("new", items: [reply("Newest answer")]),
            turn("working", status: "inProgress", items: [reply("Excluded streaming answer")]),
            turn("interrupted", status: "interrupted", items: [reply("Excluded interrupted answer")]),
            turn("old", items: [
                .object(["type": .string("userMessage"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Opening question")]),
                    .object(["type": .string("image"), "url": .string("Excluded image")])
                ])]),
                .object(["type": .string("commandExecution"), "text": .string("Excluded tool output")]),
                reply("Old answer")
            ])
        ]
        let prompt = try #require(CodexSideQuestion.prompt(question: "What happened?", turns: turns, excluding: "live"))
        #expect(!prompt.contains("Excluded"))
        #expect(prompt.components(separatedBy: "Opening question").last?.contains("Old answer") == true)
        #expect(prompt.components(separatedBy: "Old answer").last?.contains("Newest answer") == true)
    }

    @Test func boundsSnapshotAndQuestion() throws {
        let turns = [turn("latest", items: [reply(String(repeating: "a", count: 30_000))]),
                     turn("old", items: [reply("Earlier answer")])]
        let prompt = try #require(CodexSideQuestion.prompt(
            question: String(repeating: "b", count: 4_000), turns: turns, excluding: nil
        ))
        #expect(prompt.contains(String(repeating: "a", count: 20_000)))
        #expect(!prompt.contains(String(repeating: "a", count: 20_001)))
        #expect(!prompt.contains("Earlier answer"))
        #expect(prompt.hasSuffix(String(repeating: "b", count: 4_000)))
        #expect(CodexSideQuestion.prompt(question: String(repeating: "b", count: 4_001),
                                         turns: turns, excluding: nil) == nil)
    }

    @Test func emptySnapshotSkipsInference() {
        #expect(CodexSideQuestion.prompt(question: "Hello", turns: [], excluding: nil) == nil)
        let working = turn("live", status: "inProgress", items: [reply("Partial")])
        #expect(CodexSideQuestion.prompt(question: "Hello", turns: [working], excluding: nil) == nil)
    }

    @Test func sideQuestionUsesStdinAndEphemeralToolFreeConfiguration() {
        let args = CodexEphemeralInference.arguments(directory: URL(fileURLWithPath: "/tmp/side"),
                                                     request: .sideQuestion("Private snapshot"))
        #expect(args.last == "-")
        #expect(!args.contains { $0.contains("Private snapshot") })
        #expect(!args.contains("--output-schema"))
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config", "read-only",
                     "web_search=\"disabled\"", "shell_tool", "multi_agent", "code_mode_host"] {
            #expect(args.contains(flag))
        }
    }

    @Test func hungHistoryReadTimesOut() async {
        let client = CodexAppServerClient { _ in true }
        await #expect(throws: CodexAppServerClient.SideQuestionHistoryTimeout.self) {
            try await client.readSideQuestionTurns(threadID: "thread", timeout: .milliseconds(10))
        }
    }

    @Test func cancelingHistoryReadReleasesItsWaiter() async {
        let (requests, requestWriter) = AsyncStream.makeStream(of: String.self)
        let client = CodexAppServerClient { line in
            requestWriter.yield(line)
            return true
        }
        let pending = Task { try await client.readSideQuestionTurns(threadID: "thread") }
        var requestIterator = requests.makeAsyncIterator()
        _ = await requestIterator.next()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    private func turn(_ id: String, status: String = "completed", items: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "items": .array(items)])
    }

    private func reply(_ text: String) -> JSONValue {
        .object(["type": .string("agentMessage"), "text": .string(text)])
    }
}
