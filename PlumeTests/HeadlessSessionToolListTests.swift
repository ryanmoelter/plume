import Foundation
import Testing
@testable import Plume

/// The `tools` list of each `system`/`init` event lands on the session, and a
/// later `init` replaces it.
@MainActor
struct HeadlessSessionToolListTests {
    private func initLine(tools: String) -> String {
        #"{"type":"system","subtype":"init","session_id":"s1","cwd":"/tmp","model":"haiku","permissionMode":"default","tools":\#(tools),"slash_commands":[]}"#
    }

    private func feed(_ tools: String, to session: HeadlessSession) throws {
        session.handle(try #require(StreamJSONDecoder.decode(line: initLine(tools: tools))))
    }

    @Test func recordsTheInitToolList() throws {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())
        #expect(session.toolNames.isEmpty)

        try feed(#"["Bash","Read","Edit"]"#, to: session)

        #expect(session.toolNames == ["Bash", "Read", "Edit"])
    }

    @Test func aLaterInitReplacesTheList() throws {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())
        try feed(#"["Bash","Read"]"#, to: session)
        try feed(#"["Bash","Read","Artifact"]"#, to: session)

        #expect(session.toolNames == ["Bash", "Read", "Artifact"])
    }

    @Test func skipsNonStringEntries() throws {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())
        try feed(#"["Bash",1,null,"Read"]"#, to: session)

        #expect(session.toolNames == ["Bash", "Read"])
    }
}
