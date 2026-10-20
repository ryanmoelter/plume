import Foundation
import Testing
@testable import Plume

struct TaskIntegrationsTests {
    private func ref(_ id: String, org: String? = nil) -> LinearIssueRef {
        LinearIssueRef(orgID: org, identifier: id)
    }

    @Test func roundTrips() throws {
        var links = LinearTaskLinks()
        links.link(ref("PLUME-1", org: "o1"))
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
        #expect(decoded.linear?.dismissed == [])
        #expect(TaskIntegrations.decode(Data("{}".utf8)).linear == nil)
    }

    @Test func linkUndismisses() {
        var links = LinearTaskLinks()
        links.unlink("PLUME-1")
        #expect(links.dismissed == ["PLUME-1"])
        links.link(ref("PLUME-1"))
        #expect(links.dismissed.isEmpty)
        #expect(links.manual.map(\.identifier) == ["PLUME-1"])
    }

    @Test func unlinkRemovesEverywhereAndDismisses() {
        var links = LinearTaskLinks()
        links.link(ref("PLUME-1"))
        links.promote(ref("PLUME-1"))
        links.recordAgentStarted(ref("PLUME-1"))
        links.unlink("plume-1")
        #expect(links.manual.isEmpty && links.promoted.isEmpty && links.agentStarted.isEmpty)
        #expect(links.dismissed == ["PLUME-1"])
        links.unlink("PLUME-1")
        #expect(links.dismissed == ["PLUME-1"])
    }

    @Test func recordAgentStartedReportsChange() {
        var links = LinearTaskLinks()
        let first = links.recordAgentStarted(ref("PLUME-1"))
        let repeated = links.recordAgentStarted(ref("PLUME-1"))
        links.unlink("PLUME-2")
        let dismissed = links.recordAgentStarted(ref("PLUME-2"))
        #expect(first)
        #expect(!repeated)
        #expect(!dismissed)
        #expect(links.agentStarted.map(\.identifier) == ["PLUME-1"])
    }

    @Test func promoteDoesNotDuplicate() {
        var links = LinearTaskLinks()
        links.promote(ref("PLUME-1"))
        links.promote(ref("PLUME-1", org: "o"))
        #expect(links.promoted == [ref("PLUME-1", org: "o")])
    }
}
