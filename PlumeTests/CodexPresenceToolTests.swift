import Testing
@testable import Plume

struct CodexPresenceToolTests {
    @Test func readsPresenceAsPlainText() {
        let result = CodexPresenceTool.call(.object([
            "tool": .string("plume_presence"), "arguments": .object([:]), "namespace": .null
        ])) {
            Presence.report(displays: [], locked: true)
        }
        #expect(result["success"] == .bool(true))
        #expect(result["contentItems"]?.arrayValue?.first?["text"] == .string("locked"))
    }

    @Test func rejectsOtherToolsAndArgumentsWithoutReadingPresence() {
        let arguments: [[String: JSONValue]] = [
            ["tool": .string("presence"), "arguments": .object([:])],
            ["namespace": .string("other"), "tool": .string("plume_presence"), "arguments": .object([:])],
            ["tool": .string("plume_presence"), "arguments": .object(["target": .string("other")])]
        ]
        for request in arguments {
            let result = CodexPresenceTool.call(.object(request)) {
                Issue.record("The tool read presence for an invalid request")
                return Presence.report(displays: [], locked: false)
            }
            #expect(result["success"] == .bool(false))
        }
    }
}
