import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexTitleTests {
    @Test func titleOutputMustBeShortStructuredText() {
        #expect(CodexTitleGenerator.validatedTitle(#"{"title":"  Add Codex support  "}"#) == "Add Codex support")
        #expect(CodexTitleGenerator.validatedTitle("Add Codex support") == nil)
        #expect(CodexTitleGenerator.validatedTitle(#"{"title":"a\nb"}"#) == nil)
        #expect(CodexTitleGenerator.validatedTitle(#"{"title":""}"#) == nil)
    }

    @Test func titleRequestIsEphemeralAndExcludesUserConfigurationAndTools() {
        let args = CodexTitleGenerator.arguments(directory: URL(fileURLWithPath: "/tmp/title test"), description: "Fix a bug")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config"] {
            #expect(args.contains(flag))
        }
        #expect(args.contains("tools.update_plan.enabled=false"))
        #expect(args.contains("tools.experimental_request_user_input.enabled=false"))
        #expect(args.contains("project_doc_max_bytes=0"))
        #expect(args.contains("model_catalog_json=\"/tmp/title test/catalog.json\""))
        #expect(args[2] == "exec \"$@\" </dev/null")
    }

    @MainActor private final class Harness {
        var client: CodexAppServerClient!
        var names: [String] = []
        var turns = 0
        var serverName: String?
        var beforeNameResponse: (() -> Void)?
        init(serverName: String? = nil) {
            self.serverName = serverName
            client = CodexAppServerClient { [weak self] line in
                guard let self, let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let id = request["id"], let method = request["method"]?.stringValue else { return true }
                let result: JSONValue
                switch method {
                case "thread/start":
                    var thread: [String: JSONValue] = ["id": .string("title-thread"), "preview": .string("Provisional preview")]
                    if let serverName { thread["name"] = .string(serverName) }
                    result = .object(["thread": .object(thread)])
                case "turn/start":
                    turns += 1
                    result = .object(["turn": .object(["id": .string("turn-\(turns)")])])
                case "thread/name/set":
                    names.append(request["params"]?["name"]?.stringValue ?? "")
                    beforeNameResponse?()
                    result = .object([:])
                default: result = .object(["data": .array([])])
                }
                let data = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
                client.receive(String(decoding: data, as: UTF8.self))
                return true
            }
        }
        func complete() {
            client.receive("{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"title-thread\",\"turn\":{\"id\":\"turn-\(turns)\",\"status\":\"completed\"}}}")
        }
    }

    @Test func firstCompletedTurnReplacesPreviewOnlyOnce() async throws {
        let harness = Harness()
        var descriptions: [String] = []
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: harness.client, generateTitle: {
            descriptions.append($0)
            return "Implement Codex titles"
        })
        defer { session.stop() }
        session.titleContextProvider = { _ in (.headless, nil) }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "Please implement generated Codex conversation titles")
        try await until { harness.turns == 1 }
        #expect(descriptions.isEmpty)
        harness.complete()
        try await until { harness.names.count == 1 }
        #expect(descriptions == ["Please implement generated Codex conversation titles"])
        #expect(harness.names == ["Implement Codex titles"])
        session.submit(text: "Continue")
        try await until { harness.turns == 2 }
        harness.complete()
        for _ in 0..<20 { await Task.yield() }
        #expect(descriptions.count == 1)
    }

    @Test func customTaskAndExistingServerNamesSuppressInitialInference() async throws {
        for namedTask in [true, false] {
            let harness = Harness(serverName: namedTask ? nil : "Existing name")
            var requests = 0
            let session = CodexSession(tabID: UUID(), taskID: UUID(), client: harness.client, generateTitle: { _ in
                requests += 1
                return "Unexpected"
            })
            session.titleContextProvider = { _ in (.headless, namedTask ? "My work" : nil) }
            session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
            session.submit(text: "Fix a bug")
            try await until { harness.turns == 1 }
            harness.complete()
            for _ in 0..<20 { await Task.yield() }
            #expect(requests == 0)
            session.stop()
        }
    }

    @Test func newerServerNameWinsWhileNameSetReplyIsPending() async throws {
        let harness = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: harness.client, generateTitle: { _ in "Generated title" })
        defer { session.stop() }
        session.titleContextProvider = { _ in (.headless, nil) }
        harness.beforeNameResponse = {
            harness.client.receive(#"{"method":"thread/name/updated","params":{"threadId":"title-thread","threadName":"User's newer title"}}"#)
        }
        session.start(workingDirectory: nil, resumeThreadID: nil, model: nil, environment: [:])
        session.submit(text: "Fix a bug")
        try await until { harness.turns == 1 }
        harness.complete()
        try await until { harness.names.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(TitleStore.shared.title(forTab: session.tabID) == "User's newer title")
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }
}
