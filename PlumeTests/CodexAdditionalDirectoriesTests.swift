import Foundation
import Testing

@testable import Plume

@MainActor
struct CodexAdditionalDirectoriesTests {
    @MainActor
    private final class Harness {
        var client: CodexAppServerClient!
        var requests: [(String, JSONValue)] = []
        var reportsRoots = true
        var resumedRoots: [String] = []

        init() {
            client = CodexAppServerClient { [weak self] line in
                guard let self,
                      let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      let id = message["id"], let method = message["method"]?.stringValue else { return true }
                let params = message["params"] ?? .object([:])
                requests.append((method, params))
                var result: JSONValue = .object(["data": .array([])])
                switch method {
                case "permissionProfile/list":
                    result = .object(["data": .array([":read-only", ":workspace", "custom"].map { .object(["id": .string($0)]) })])
                case "thread/start", "thread/resume":
                    var fields: [String: JSONValue] = ["thread": .object(["id": .string("thread"), "cwd": .string("/workspace")]), "cwd": .string("/workspace")]
                    if reportsRoots {
                        fields["runtimeWorkspaceRoots"] = params["runtimeWorkspaceRoots"] ?? .array((["/workspace"] + resumedRoots).map(JSONValue.string))
                    }
                    result = .object(fields)
                case "turn/start": result = .object(["turn": .object(["id": .string("turn")])])
                default: break
                }
                let response = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": result]))
                client.receive(String(decoding: response, as: UTF8.self))
                return true
            }
        }
        func params(_ method: String) -> JSONValue? { requests.last { $0.0 == method }?.1 }
        func complete() {
            client.receive(#"{"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}}"#)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true")
        throw CancellationError()
    }

    @Test(arguments: [":read-only", ":workspace", "custom"])
    func rootsPreserveTheSelectedProfile(_ profile: String) async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: "/workspace", resumeThreadID: nil, model: nil, permissionProfile: profile, environment: [:], additionalDirectories: ["/extra", "/workspace", "/extra"])
        session.submit(blocks: [.text("hello")])
        try await waitUntil { h.params("turn/start") != nil }
        for method in ["thread/start", "turn/start"] {
            let params = try #require(h.params(method))
            #expect(params["permissions"]?.stringValue == profile)
            #expect(params["runtimeWorkspaceRoots"] == .array([.string("/workspace"), .string("/extra")]))
            #expect(params["sandbox"] == nil)
            #expect(params["sandboxPolicy"] == nil)
            #expect(params["approvalPolicy"] == nil)
        }
    }

    @Test func replacementsAndClearWaitForTheNextTurn() async throws {
        let h = Harness()
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: "/workspace", resumeThreadID: nil, model: nil, environment: [:], additionalDirectories: ["/first"])
        session.submit(blocks: [.text("first")])
        try await waitUntil { session.appliedAdditionalDirectories == ["/first"] && h.params("turn/start") != nil }
        session.setAdditionalDirectories(["/second"])
        #expect(session.hasPendingAdditionalDirectories)
        #expect(session.appliedAdditionalDirectories == ["/first"])
        h.complete()
        session.submit(blocks: [.text("second")])
        try await waitUntil { session.appliedAdditionalDirectories == ["/second"] }
        #expect(h.params("turn/start")?["runtimeWorkspaceRoots"] == .array([.string("/workspace"), .string("/second")]))
        session.setAdditionalDirectories([])
        h.complete()
        session.submit(blocks: [.text("third")])
        try await waitUntil { session.appliedAdditionalDirectories.isEmpty }
        #expect(h.params("turn/start")?["runtimeWorkspaceRoots"] == .array([.string("/workspace")]))
        #expect(!session.hasPendingAdditionalDirectories)
    }

    @Test func persistedRemovalClearsResumedRoots() async throws {
        let h = Harness()
        h.resumedRoots = ["/old"]
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: "/workspace", resumeThreadID: "thread", model: nil, environment: [:], replaceAdditionalDirectories: true)
        try await waitUntil { h.params("thread/items/list") != nil }
        #expect(h.params("thread/resume")?["runtimeWorkspaceRoots"] == .array([.string("/workspace")]))
        #expect(session.appliedAdditionalDirectories.isEmpty)
    }

    @Test func remoteAttachmentPreservesAndAdoptsServerRoots() async throws {
        let h = Harness()
        h.resumedRoots = ["/remote"]
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        var adopted: [String] = []
        session.onAdoptDirectories = { adopted = $0 }
        defer { session.stop() }
        session.start(workingDirectory: "/workspace", resumeThreadID: "thread", model: nil, preserveRemoteConfiguration: true, environment: [:], additionalDirectories: ["/stale"], replaceAdditionalDirectories: true)
        try await waitUntil { h.params("thread/items/list") != nil }
        #expect(h.params("thread/resume")?["runtimeWorkspaceRoots"] == nil)
        #expect(h.params("thread/resume")?["permissions"] == nil)
        #expect(session.appliedAdditionalDirectories == ["/remote"])
        #expect(adopted == ["/remote"])
        #expect(!session.hasPendingAdditionalDirectories)
    }

    @Test func olderServersKeepDefaultChatsButRejectFolderChanges() async throws {
        let h = Harness()
        h.reportsRoots = false
        let session = CodexSession(tabID: UUID(), taskID: UUID(), client: h.client)
        defer { session.stop() }
        session.start(workingDirectory: "/workspace", resumeThreadID: nil, model: nil, environment: [:])
        session.submit(blocks: [.text("first")])
        try await waitUntil { h.params("turn/start") != nil }
        #expect(h.params("thread/start")?["runtimeWorkspaceRoots"] == nil)
        #expect(h.params("turn/start")?["runtimeWorkspaceRoots"] == nil)
        session.setAdditionalDirectories(["/extra"])
        h.complete()
        session.submit(blocks: [.text("second")])
        try await waitUntil { session.lastError != nil }
        #expect(session.lastError?.contains("Update Codex") == true)
        #expect(h.requests.filter { $0.0 == "turn/start" }.count == 1)
        #expect(session.queuedMessages.map(\.plainText) == ["second"])
    }
}
