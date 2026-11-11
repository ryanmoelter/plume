import Foundation
import Testing
@testable import Plume

/// The suggestions are the shapes Claude Code 2.1.321 sent for a Bash call,
/// an in-project Write and a Write outside the working directory.
@MainActor
struct PermissionSuggestionTests {
    private static let request = #"""
    {"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm --version"},"permission_suggestions":[
      {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm --version"}],"behavior":"allow","destination":"localSettings"},
      {"type":"setMode","mode":"acceptEdits","destination":"session"},
      {"type":"addDirectories","directories":["/tmp","/private/tmp"],"destination":"session"},
      {"type":"removeDirectories","directories":["/x"],"destination":"session"},
      {"type":"addRules","rules":[{"toolName":"Bash"}],"behavior":"deny","destination":"session"}]}}
    """#

    private func decodedRequest(_ line: String = request) throws -> ControlRequest {
        let flattened = line.replacingOccurrences(of: "\n", with: "")
        guard case .controlRequest(let request)? = StreamJSONDecoder.decode(line: flattened) else {
            Issue.record("expected a control request")
            throw CancellationError()
        }
        return request
    }

    private func makeSession() -> HeadlessSession {
        let backgroundTasks = BackgroundTaskTracker()
        let engine = StatusEngine(backgroundTasks: backgroundTasks)
        let session = HeadlessSession(tabID: UUID(), taskID: UUID(), statusEngine: engine, backgroundTasks: backgroundTasks)
        engine.register(tabID: session.tabID, taskID: session.taskID)
        return session
    }

    @Test func decodesOnlyTheSuggestionsThatGrantSomething() throws {
        let suggestions = try decodedRequest().permissionSuggestions

        #expect(suggestions.map(\.kind) == [
            .allowRules([.init(toolName: "Bash", ruleContent: "npm --version")]),
            .setMode("acceptEdits"),
            .addDirectories(["/tmp", "/private/tmp"])
        ])
        #expect(suggestions.map(\.id) == [0, 1, 2])
        #expect(suggestions.map(\.destination) == ["localSettings", "session", "session"])
    }

    @Test func suppressingTheAlwaysAllowRuleDropsRules() throws {
        let line = Self.request.replacingOccurrences(
            of: #""subtype":"can_use_tool","#,
            with: #""subtype":"can_use_tool","suppress_always_allow_rule":true,"#
        )
        let suggestions = try decodedRequest(line).permissionSuggestions

        #expect(suggestions.map(\.id) == [1, 2])
    }

    @Test func labelsSayWhatIsAllowedAndForHowLong() throws {
        let labels = try decodedRequest().permissionSuggestions.map(\.label)

        #expect(labels == [
            "Always allow “npm --version” in this project",
            "Allow all edits this session",
            "Allow access to /tmp, /private/tmp this session"
        ])
    }

    @Test func aNonBashRuleUsesTheRuleSyntax() {
        let suggestions = PermissionSuggestion.decoding(.array([.object([
            "type": .string("addRules"),
            "behavior": .string("allow"),
            "destination": .string("userSettings"),
            "rules": .array([
                .object(["toolName": .string("WebFetch"), "ruleContent": .string("domain:example.com")]),
                .object(["toolName": .string("Read")])
            ])
        ])]))

        #expect(suggestions.first?.label == "Always allow WebFetch(domain:example.com), Read everywhere")
        #expect(suggestions.first?.persistsBeyondSession == true)
    }

    @Test func acceptingEchoesTheSuggestionInUpdatedPermissions() throws {
        let request = try decodedRequest()
        let session = makeSession()
        var lines: [String] = []
        session.debugLineSink = { lines.append($0) }
        session.handle(.controlRequest(request))
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, accepting: permission.suggestions[0])

        let sent = try #require(lines.last)
        guard case .controlResponse(let response)? = StreamJSONDecoder.decode(line: sent) else {
            Issue.record("expected a control response")
            return
        }
        let root = response.payload
        #expect(root["behavior"]?.stringValue == "allow")
        #expect(root["updatedInput"]?.objectValue == request.input)
        #expect(root["updatedPermissions"]?.arrayValue == [permission.suggestions[0].raw])
        #expect(session.pendingPermissions.isEmpty)
    }

    @Test func aPlainAllowSendsNoUpdatedPermissions() throws {
        let session = makeSession()
        var lines: [String] = []
        session.debugLineSink = { lines.append($0) }
        session.handle(.controlRequest(try decodedRequest()))
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, with: .allow(updatedInput: permission.input))

        #expect(try #require(lines.last).contains("updatedPermissions") == false)
    }

    @Test func acceptingASetModeShowsTheNewModeAtOnce() throws {
        let session = makeSession()
        session.debugLineSink = { _ in }
        session.handle(.controlRequest(try decodedRequest()))
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, accepting: permission.suggestions[1])

        #expect(session.permissionMode == .acceptEdits)
    }

    @Test func acceptingAddDirectoriesGrantsTheFoldersWithoutARestart() throws {
        let session = makeSession()
        session.debugLineSink = { _ in }
        session.declinedDirectories = { ["/tmp"] }
        var granted: [String] = []
        session.onGrantDirectories = { granted += $0 }
        session.handle(.controlRequest(try decodedRequest()))
        let permission = try #require(session.pendingPermissions.first)

        session.resolve(permission, accepting: permission.suggestions[2])

        #expect(granted == ["/tmp", "/private/tmp"])
        #expect(session.launchAdditionalDirectories == ["/tmp", "/private/tmp"])
    }
}
