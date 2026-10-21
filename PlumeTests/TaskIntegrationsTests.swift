import Foundation
import Testing
@testable import Plume

struct TaskIntegrationsTests {
    private func ref(_ id: String) -> LinearIssueRef {
        LinearIssueRef(identifier: id)
    }

    @Test func roundTrips() throws {
        var links = LinearTaskLinks()
        links.link(ref("PLUME-1"))
        links.promote(ref("PLUME-2"))
        links.recordAgentStarted(ref("PLUME-3"))
        links.unlink("PLUME-9")
        let value = TaskIntegrations(linear: links)
        let decoded = TaskIntegrations.decode(value.encoded())
        #expect(decoded == value)
    }

    @Test func garbageAndNilGiveEmpty() {
        #expect(TaskIntegrations.decode(nil) == TaskIntegrations())
        #expect(TaskIntegrations.decode(Data("not json".utf8)) == TaskIntegrations())
        #expect(TaskIntegrations.decode(Data("[1,2]".utf8)) == TaskIntegrations())
    }

    @Test func toleratesUnknownAndMissingFields() {
        let json = #"{"version":3,"future":{"x":1},"linear":{"manual":[{"identifier":"PLUME-5"}],"extra":true}}"#
        let decoded = TaskIntegrations.decode(Data(json.utf8))
        #expect(decoded.version == 3)
        #expect(decoded.linear?.manual.map(\.identifier) == ["PLUME-5"])
        #expect(decoded.linear?.unlinked == [])
        #expect(TaskIntegrations.decode(Data("{}".utf8)).linear == nil)
    }

    @Test func malformedElementsAreSkippedNotTheWholeList() {
        let json = #"{"linear":{"manual":[{"identifier":"PLUME-1"},{"identifier":7},"junk",{"identifier":"PLUME-2"}],"unlinked":["U-1",null,"U-2"],"dismissed":["A-1",3,"A-2"]}}"#
        let decoded = TaskIntegrations.decode(Data(json.utf8))
        #expect(decoded.linear?.manual.map(\.identifier) == ["PLUME-1", "PLUME-2"])
        #expect(decoded.linear?.unlinked == ["U-1", "U-2", "A-1", "A-2"])
    }

    @Test func legacyDismissedDecodesIntoUnlinkedWithoutDuplicates() {
        let json = #"{"linear":{"unlinked":["A-1"],"dismissed":["A-1","A-2",5]}}"#
        let decoded = TaskIntegrations.decode(Data(json.utf8))
        #expect(decoded.linear?.unlinked == ["A-1", "A-2"])
    }

    @Test func encodingDropsTheLegacyDismissedKey() throws {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        let data = try #require(TaskIntegrations(linear: links).encoded())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("dismissed"))
    }

    @Test func linkClearsUnlinked() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        links.link(ref("PLUME-1"))
        #expect(links.unlinked.isEmpty)
        #expect(links.manual.map(\.identifier) == ["PLUME-1"])
    }

    @Test func promoteClearsUnlinked() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        links.promote(ref("PLUME-1"))
        #expect(links.unlinked.isEmpty)
        #expect(links.promoted.map(\.identifier) == ["PLUME-1"])
    }

    @Test func unlinkRemovesEverywhereAndRecordsUnlinked() {
        var links = LinearTaskLinks()
        links.link(ref("PLUME-1"))
        links.promote(ref("PLUME-1"))
        links.recordAgentStarted(ref("PLUME-1"))
        links.unlink("plume-1")
        #expect(links.manual.isEmpty && links.promoted.isEmpty && links.agentStarted.isEmpty)
        #expect(links.unlinked == ["PLUME-1"])
        links.unlink("PLUME-1")
        #expect(links.unlinked == ["PLUME-1"])
    }

    @Test func recordAgentStartedReportsChange() {
        var links = LinearTaskLinks()
        let first = links.recordAgentStarted(ref("PLUME-1"))
        let repeated = links.recordAgentStarted(ref("PLUME-1"))
        links.unlink("PLUME-3")
        let unlinked = links.recordAgentStarted(ref("PLUME-3"))
        #expect(first)
        #expect(!repeated)
        #expect(!unlinked)
        #expect(links.agentStarted.map(\.identifier) == ["PLUME-1"])
    }

    @Test func promoteDoesNotDuplicate() {
        var links = LinearTaskLinks()
        links.promote(ref("PLUME-1"))
        links.promote(ref("plume-1"))
        #expect(links.promoted == [ref("PLUME-1")])
    }

    @Test func aLegacyOrgIDOnARefStillDecodes() {
        let json = #"{"linear":{"manual":[{"orgID":"o1","identifier":"PLUME-5"}]}}"#
        let decoded = TaskIntegrations.decode(Data(json.utf8))
        #expect(decoded.linear?.manual == [ref("PLUME-5")])
    }
}
