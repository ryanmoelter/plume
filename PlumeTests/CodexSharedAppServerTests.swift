import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexSharedAppServerTests {
    @Test func coalescesHandshakeAndKeepsOtherEndpointAlive() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let first = CodexAppServerClient(sharedServer: host)
        let second = CodexAppServerClient(sharedServer: host)
        try first.start(workingDirectory: nil, environment: [:])
        try second.start(workingDirectory: nil, environment: [:])
        let a = Task { try await first.send("initialize") }
        let b = Task { try await second.send("initialize") }
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        #expect(lines.count == 1)
        wire.receive(#"{"id":1,"result":{"userAgent":"test"}}"#)
        let firstReply = try await a.value
        let secondReply = try await b.value
        #expect(firstReply == secondReply)
        first.notify("initialized")
        second.notify("initialized")
        #expect(lines.count == 2)
        first.stop()
        let request = Task { try await second.send("thread/read") }
        for _ in 0..<100 { if lines.count == 3 { break }; await Task.yield() }
        wire.receive(#"{"id":2,"result":{"alive":true}}"#)
        let reply = try await request.value
        #expect(reply["alive"]?.boolValue == true)
        second.stop()
    }

    @Test func fansOutScopedRequestsButAnswersOnlyOnce() throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let a = CodexAppServerClient(sharedServer: host)
        let b = CodexAppServerClient(sharedServer: host)
        try a.start(workingDirectory: nil, environment: [:])
        try b.start(workingDirectory: nil, environment: [:])
        var deliveries = 0
        a.onServerRequest = { id, _, _ in deliveries += 1; a.respond(to: id, result: .null) }
        b.onServerRequest = { id, _, _ in deliveries += 1; b.respond(to: id, result: .null) }
        wire.receive(#"{"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"child"}}"#)
        #expect(deliveries == 2)
        #expect(lines.count == 1)
        wire.receive(#"{"id":43,"method":"unknown/global","params":{}}"#)
        #expect(deliveries == 3)
        #expect(lines.count == 2)
        a.stop(); b.stop()
    }

    @Test func detachedHandshakeCannotReturnLateSuccess() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let a = CodexAppServerClient(sharedServer: host)
        let b = CodexAppServerClient(sharedServer: host)
        try a.start(workingDirectory: nil, environment: [:])
        try b.start(workingDirectory: nil, environment: [:])
        let request = Task { try await host.send(from: a, method: "initialize", params: .null) }
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        a.stop()
        wire.receive(#"{"id":1,"result":{}}"#)
        do { _ = try await request.value; Issue.record("Detached handshake succeeded") }
        catch { #expect(error as? CodexAppServerClient.Failure == .notRunning) }
        b.stop()
    }

    @Test func detachingFailsOnlyItsPendingRequest() async throws {
        let wire = CodexAppServerClient(writeLine: { _ in true })
        let host = CodexSharedAppServer(physical: wire)
        let a = CodexAppServerClient(sharedServer: host)
        let b = CodexAppServerClient(sharedServer: host)
        try a.start(workingDirectory: nil, environment: [:])
        try b.start(workingDirectory: nil, environment: [:])
        let pending = Task { try await a.send("thread/read") }
        await Task.yield()
        a.stop()
        do { _ = try await pending.value; Issue.record("Detached request succeeded") }
        catch { #expect(error as? CodexAppServerClient.Failure == .notRunning) }
        #expect(a.sharedRemoteControl === b.sharedRemoteControl)
        b.stop()
    }
    @Test func localStartNotificationCannotCreateRemoteDuplicate() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let endpoint = CodexAppServerClient(sharedServer: host)
        try endpoint.start(workingDirectory: nil, environment: [:])
        var adopted = 0
        host.adoptRemoteThread = { _ in adopted += 1; return true }
        let request = Task { try await endpoint.send("thread/start") }
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        wire.receive(#"{"method":"thread/started","params":{"thread":{"id":"local"}}}"#)
        #expect(lines.count == 1)
        wire.receive(#"{"id":1,"result":{"thread":{"id":"local"}}}"#)
        _ = try await request.value
        for _ in 0..<10 { await Task.yield() }
        #expect(adopted == 0)
        #expect(lines.count == 1)
        endpoint.stop()
    }

    @Test func remoteRootAdoptsThenReplaysPendingApproval() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let existing = CodexAppServerClient(sharedServer: host)
        try existing.start(workingDirectory: nil, environment: [:])
        var adopted: String?
        var delivered = 0
        var remote: CodexAppServerClient?
        host.adoptRemoteThread = { thread in
            adopted = thread["id"]?.stringValue
            let endpoint = CodexAppServerClient(sharedServer: host)
            try? endpoint.start(workingDirectory: nil, environment: [:])
            endpoint.onServerRequest = { _, _, _ in delivered += 1 }
            remote = endpoint
            return true
        }
        wire.receive(#"{"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"remote"}}"#)
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        wire.receive(#"{"id":1,"result":{"thread":{"id":"remote","cwd":"/tmp"}}}"#)
        for _ in 0..<100 { if delivered > 0 { break }; await Task.yield() }
        #expect(adopted == "remote")
        #expect(delivered == 1)
        remote?.stop()
        existing.stop()
    }

    @Test func oldReleaseCannotUnsubscribeNewResumeAndCloseDoesNotAdopt() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let endpoint = CodexAppServerClient(sharedServer: host)
        try endpoint.start(workingDirectory: nil, environment: [:])
        var adopted = 0
        host.adoptRemoteThread = { _ in adopted += 1; return true }
        host.releaseThread(threadID: "same", turnID: "turn")
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        wire.receive(#"{"method":"thread/status/changed","params":{"threadId":"same","status":{"type":"idle"}}}"#)
        #expect(lines.count == 1)
        let resume = Task { try await endpoint.send("thread/resume", .object(["threadId": .string("same")])) }
        for _ in 0..<100 { if lines.count == 2 { break }; await Task.yield() }
        wire.receive(#"{"id":1,"result":{}}"#)
        wire.receive(#"{"id":2,"result":{"thread":{"id":"same"}}}"#)
        _ = try await resume.value
        for _ in 0..<10 { await Task.yield() }
        #expect(lines.count == 2)
        #expect(adopted == 0)
        endpoint.stop()
    }

    @Test func detachedLateLocalStartIsReleasedInsteadOfAdopted() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let first = CodexAppServerClient(sharedServer: host)
        let survivor = CodexAppServerClient(sharedServer: host)
        try first.start(workingDirectory: nil, environment: [:])
        try survivor.start(workingDirectory: nil, environment: [:])
        var adopted = 0
        host.adoptRemoteThread = { _ in adopted += 1; return true }
        let request = Task { try await host.send(from: first, method: "thread/start", params: .object([:])) }
        for _ in 0..<100 { if !lines.isEmpty { break }; await Task.yield() }
        wire.receive(#"{"method":"thread/started","params":{"thread":{"id":"orphan"}}}"#)
        first.stop()
        wire.receive(#"{"id":1,"result":{"thread":{"id":"orphan"}}}"#)
        do { _ = try await request.value; Issue.record("Detached start succeeded") }
        catch { #expect(error as? CodexAppServerClient.Failure == .notRunning) }
        for _ in 0..<100 { if lines.count == 2 { break }; await Task.yield() }
        #expect(lines.count == 2)
        #expect(lines.last?.contains("thread/unsubscribe") == true)
        #expect(adopted == 0)
        wire.receive(#"{"id":2,"result":{}}"#)
        survivor.stop()
    }

    @Test func childApprovalWaitsForParentAttachmentAndSurvivesUnrelatedAdoption() async throws {
        var lines: [String] = []
        let wire = CodexAppServerClient(writeLine: { lines.append($0); return true })
        let host = CodexSharedAppServer(physical: wire)
        let existing = CodexAppServerClient(sharedServer: host)
        try existing.start(workingDirectory: nil, environment: [:])
        var remoteEndpoints: [CodexAppServerClient] = []
        var parentDeliveries = 0
        host.adoptRemoteThread = { thread in
            let endpoint = CodexAppServerClient(sharedServer: host)
            try? endpoint.start(workingDirectory: nil, environment: [:])
            if thread["id"]?.stringValue == "parent" {
                endpoint.onServerRequest = { id, _, params in
                    guard params["threadId"]?.stringValue == "child" else { return }
                    parentDeliveries += 1
                    endpoint.respond(to: id, result: .object(["decision": .string("accept")]))
                }
            }
            remoteEndpoints.append(endpoint)
            return true
        }
        wire.receive(#"{"id":42,"method":"item/commandExecution/requestApproval","params":{"threadId":"child"}}"#)
        for _ in 0..<100 { if lines.count == 1 { break }; await Task.yield() }
        wire.receive(#"{"id":1,"result":{"thread":{"id":"child","parentThreadId":"parent"}}}"#)
        for _ in 0..<10 { await Task.yield() }
        wire.receive(#"{"method":"thread/started","params":{"thread":{"id":"unrelated"}}}"#)
        for _ in 0..<100 { if lines.count == 2 { break }; await Task.yield() }
        wire.receive(#"{"id":2,"result":{"thread":{"id":"unrelated"}}}"#)
        for _ in 0..<100 { if remoteEndpoints.count == 1 { break }; await Task.yield() }
        #expect(parentDeliveries == 0)
        wire.receive(#"{"method":"thread/started","params":{"thread":{"id":"parent"}}}"#)
        for _ in 0..<100 { if lines.count == 3 { break }; await Task.yield() }
        wire.receive(#"{"id":3,"result":{"thread":{"id":"parent"}}}"#)
        for _ in 0..<100 { if parentDeliveries > 0 { break }; await Task.yield() }
        #expect(parentDeliveries == 1)
        #expect(lines.count == 4)
        for endpoint in remoteEndpoints { endpoint.stop() }
        existing.stop()
    }

}
