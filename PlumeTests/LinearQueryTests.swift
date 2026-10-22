import Foundation
import Testing
@testable import Plume

struct LinearQueryTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func buildsOneAliasPerIdentifier() {
        let (query, aliases) = LinearQuery.buildIssues(identifiers: ["PLUME-1", "PLUME-2"])
        #expect(aliases == ["i0": "PLUME-1", "i1": "PLUME-2"])
        #expect(query.contains("i0: issue(id: \"PLUME-1\")"))
        #expect(query.contains("i1: issue(id: \"PLUME-2\")"))
        #expect(query.contains("state { id name type color }"))
    }

    @Test func escapesIdentifiers() {
        let (query, _) = LinearQuery.buildIssues(identifiers: ["A\"B\\C/D"])
        #expect(query.contains(#"issue(id: "A\"B\\C/D")"#))
    }

    @Test func chunksAtFifty() {
        let ids = (0..<120).map { "P-\($0)" }
        let sizes = LinearQuery.chunks(of: ids).map(\.count)
        #expect(sizes == [50, 50, 20])
        #expect(LinearQuery.chunks(of: []).isEmpty)
    }

    @Test func requestBodyIsJSONWithQuery() throws {
        let body = try LinearQuery.requestBody(query: "query { x }")
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(object == ["query": "query { x }"])
    }

    private let issueJSON = """
        {"id":"uuid-102","identifier":"PLUME-102","title":"Linear","url":"https://linear.app/p/issue/PLUME-102",
         "updatedAt":"2026-10-01T12:34:56.789Z","archivedAt":null,"trashed":false,
         "state":{"id":"s-1","name":"In Progress","type":"started","color":"#f2c94c"},
         "assignee":{"id":"u-1","displayName":"ryan","name":"Ryan Moelter"},"team":{"id":"t-1","key":"PLUME"}}
        """

    @Test func decodesIssues() throws {
        let json = "{\"data\":{\"i0\":\(issueJSON)}}"
        let result = try LinearQuery.decodeIssues(data(json), aliasToIdentifier: ["i0": "plume-102"])
        guard case .found(let snapshot)? = result["PLUME-102"] else {
            Issue.record("expected an issue, got \(String(describing: result["PLUME-102"]))")
            return
        }
        let issue = snapshot.issue
        #expect(issue.title == "Linear")
        #expect(issue.stateType == .started)
        #expect(issue.stateColor == "#f2c94c")
        #expect(issue.assigneeName == "ryan")
        #expect(issue.teamKey == "PLUME")
        #expect(snapshot.id == "uuid-102")
        #expect(snapshot.teamID == "t-1")
        #expect(snapshot.state.id == "s-1")
        #expect(snapshot.assignee == LinearUser(id: "u-1", name: "ryan"))
        #expect(snapshot.updatedAt == LinearQuery.parseDate("2026-10-01T12:34:56.789Z"))
        #expect(snapshot.updatedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0.78)
    }

    @Test func nullAssigneeDecodes() throws {
        let json = """
            {"data":{"i0":{"id":"x","identifier":"A-1","title":"t","url":"u","updatedAt":"2026-10-01T00:00:00Z",
            "state":{"id":"s","name":"Todo","type":"unstarted","color":"#000000"},"assignee":null,"team":{"id":"t","key":"A"}}}}
            """
        let result = try LinearQuery.decodeIssues(data(json), aliasToIdentifier: ["i0": "A-1"])
        guard case .found(let snapshot)? = result["A-1"] else {
            Issue.record("expected an issue")
            return
        }
        #expect(snapshot.issue.assigneeName == nil)
        #expect(snapshot.assignee == nil)
    }

    @Test func aTrashedIssueIsNotFound() throws {
        let trashed = issueJSON.replacingOccurrences(of: "\"trashed\":false", with: "\"trashed\":true")
        let result = try LinearQuery.decodeIssues(data("{\"data\":{\"i0\":\(trashed)}}"), aliasToIdentifier: ["i0": "PLUME-102"])
        #expect(result["PLUME-102"] == .notFound)
    }

    @Test func theDeltaQueryFiltersFromTheBoundNewestFirstWithArchived() {
        let since = Date(timeIntervalSince1970: 1_790_000_000.5)
        let query = LinearQuery.buildIssuesUpdated(since: since)
        #expect(query.contains("updatedAt: { gte: \"\(LinearQuery.formatDate(since))\" }"))
        #expect(query.contains("orderBy: updatedAt"))
        #expect(query.contains("includeArchived: true"))
        #expect(query.contains("after: $cursor"))
        #expect(query.contains("first: \(LinearQuery.deltaPageSize)"))
        #expect(query.contains("pageInfo { hasNextPage endCursor }"))
        #expect(LinearQuery.parseDate(LinearQuery.formatDate(since)) == since)
    }

    @Test func decodesADeltaPageKeepingTrashedIssues() throws {
        let trashed = issueJSON
            .replacingOccurrences(of: "uuid-102", with: "uuid-103")
            .replacingOccurrences(of: "\"trashed\":false", with: "\"trashed\":true")
        let json = """
            {"data":{"issues":{"nodes":[\(issueJSON),\(trashed)],"pageInfo":{"hasNextPage":true,"endCursor":"c2"}}}}
            """
        let page = try LinearQuery.decodeIssuesUpdated(data(json))
        #expect(page.issues.map(\.id) == ["uuid-102", "uuid-103"])
        #expect(page.issues.map(\.isTrashed) == [false, true])
        #expect(page.nextCursor == "c2")
    }

    @Test func partialNotFoundByPathIsNil() throws {
        let json = """
            {"data":{"i0":\(issueJSON),"i1":null},
             "errors":[{"message":"Entity not found: Issue","path":["i1"],"extensions":{"code":"INVALID_INPUT"}}]}
            """
        let result = try LinearQuery.decodeIssues(
            data(json), aliasToIdentifier: ["i0": "PLUME-102", "i1": "PLUME-999"])
        #expect(result.count == 2)
        if case .found? = result["PLUME-102"] {} else { Issue.record("expected PLUME-102 found") }
        #expect(result["PLUME-999"] == .notFound)
    }

    @Test func entityNotFoundCodeIsNotFound() throws {
        let json = """
            {"data":{"i0":null},
             "errors":[{"message":"Missing","path":["i0"],"extensions":{"code":"ENTITY_NOT_FOUND"}}]}
            """
        let result = try LinearQuery.decodeIssues(data(json), aliasToIdentifier: ["i0": "A-1"])
        #expect(result["A-1"] == .notFound)
    }

    @Test func anOtherAliasScopedErrorFailsOnlyThatIssue() throws {
        let json = """
            {"data":{"i0":\(issueJSON),"i1":null},
             "errors":[{"message":"Internal error","path":["i1"],"extensions":{"code":"INTERNAL_SERVER_ERROR"}}]}
            """
        let result = try LinearQuery.decodeIssues(
            data(json), aliasToIdentifier: ["i0": "PLUME-102", "i1": "PLUME-999"])
        if case .found? = result["PLUME-102"] {} else { Issue.record("expected PLUME-102 found") }
        #expect(result["PLUME-999"] == .failed("Internal error"))
    }

    @Test func pathlessErrorFailsWholeRequest() {
        let json = #"{"errors":[{"message":"boom"}]}"#
        #expect(throws: LinearError.failed("boom")) {
            try LinearQuery.decodeIssues(data(json), aliasToIdentifier: ["i0": "A-1"])
        }
    }

    @Test func authenticationErrorIsUnauthorizedEvenWithAliasPath() {
        let json = #"{"errors":[{"message":"no","path":["i0"],"extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#
        #expect(throws: LinearError.unauthorized) {
            try LinearQuery.decodeIssues(data(json), aliasToIdentifier: ["i0": "A-1"])
        }
    }

    @Test func rateLimitedErrorCarriesResetDate() throws {
        let json = #"{"errors":[{"message":"slow down","extensions":{"code":"RATELIMITED"}}]}"#
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            _ = try LinearQuery.decodeViewer(data(json), now: now)
            Issue.record("expected a throw")
        } catch let error as LinearError {
            #expect(error == .rateLimited(until: now.addingTimeInterval(60)))
        }
    }

    @Test func malformedResponseFails() {
        #expect(throws: LinearError.self) { try LinearQuery.decodeViewer(data("nope")) }
    }

    @Test func decodesViewer() throws {
        let json = """
            {"data":{"viewer":{"name":"Ryan Moelter","displayName":"ryan"},
            "organization":{"id":"org-1","name":"Plume","urlKey":"plume-term"}}}
            """
        let account = try LinearQuery.decodeViewer(data(json))
        #expect(account == LinearAccount(
            orgID: "org-1", orgName: "Plume", urlKey: "plume-term", viewerName: "ryan"))
    }

    private let teamsPageJSON = """
        {"data":{"organization":{"id":"org-1"},"teams":{"nodes":[
          {"id":"t1","key":"plume","name":"Plume"},{"id":"t2","key":"droid","name":"Android"}],
          "pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}
        """

    private let statesPageJSON = """
        {"data":{"workflowStates":{"nodes":[
          {"id":"s1","name":"Backlog","type":"backlog","color":"#bec2c8","team":{"id":"t1"}},
          {"id":"s2","name":"Done","type":"completed","color":"#5e6ad2","team":{"id":"t1"}},
          {"id":"s3","name":"Weird","type":"somethingnew","color":"#000000","team":{"id":"t2"}},
          {"id":"s4","name":"Orphan","type":"started","color":"#111111","team":{"id":"gone"}}],
          "pageInfo":{"hasNextPage":false,"endCursor":null}}}}
        """

    @Test func decodesTeamsPage() throws {
        let page = try LinearQuery.decodeTeamsPage(data(teamsPageJSON))
        #expect(page.orgID == "org-1")
        #expect(page.teams.map(\.id) == ["t1", "t2"])
        #expect(page.nextCursor == "c1")
    }

    @Test func decodesStatesPageAndStopsWithoutNextPage() throws {
        let page = try LinearQuery.decodeStatesPage(data(statesPageJSON))
        #expect(page.states.count == 4)
        #expect(page.states[2].type == .other("somethingnew"))
        #expect(page.nextCursor == nil)
    }

    @Test func groupsStatesIntoTeamsAndDropsOrphans() throws {
        let teams = try LinearQuery.decodeTeamsPage(data(teamsPageJSON)).teams
        let states = try LinearQuery.decodeStatesPage(data(statesPageJSON)).states
        let now = Date(timeIntervalSince1970: 5)
        let catalog = LinearQuery.assembleCatalog(orgID: "org-1", teams: teams, states: states, now: now)
        #expect(catalog.orgID == "org-1")
        #expect(catalog.fetchedAt == now)
        let plume = try #require(catalog.team(key: "PLUME"))
        #expect(plume.states.map(\.type) == [.backlog, .completed])
        let droid = try #require(catalog.team(key: "DROID"))
        #expect(droid.states.map(\.type) == [.other("somethingnew")])
        #expect(catalog.teams.flatMap(\.states).count == 3)
    }

    @Test func catalogQueriesAreFlatAndPaginated() {
        #expect(LinearQuery.teamsQuery.contains("teams(first: 50, after: $cursor)"))
        #expect(LinearQuery.teamsQuery.contains("organization { id }"))
        #expect(!LinearQuery.teamsQuery.contains("states"))
        #expect(LinearQuery.statesQuery.contains("workflowStates(first: 100, after: $cursor)"))
        #expect(LinearQuery.statesQuery.contains("team { id }"))
        #expect(LinearQuery.statesQuery.contains("pageInfo { hasNextPage endCursor }"))
    }

    @Test func requestBodyCarriesTheCursorAsAVariable() throws {
        let body = try LinearQuery.requestBody(query: "query { x }", cursor: "a\"b")
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["query"] as? String == "query { x }")
        #expect((object["variables"] as? [String: String]) == ["cursor": "a\"b"])
    }
}
