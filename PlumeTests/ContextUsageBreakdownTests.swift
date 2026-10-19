import Foundation
import Testing
@testable import Plume

/// The `get_context_usage` reply parser, and the request's correlation
/// through `HeadlessSession` with `debugLineSink` standing in for the process.
@MainActor
struct ContextUsageBreakdownTests {
    /// Captured from CLI 2.1.296, with `gridRows` trimmed.
    nonisolated private static let reply = """
    {"type":"control_response","response":{"subtype":"success","request_id":"REQUEST","response":{"categories":[{"name":"System prompt","tokens":2145,"color":"promptBorder","kind":"used"},{"name":"System tools","tokens":6730,"kind":"used"},{"name":"System tools (deferred)","tokens":26459,"isDeferred":true,"kind":"deferred"},{"name":"Memory files","tokens":16824,"kind":"used"},{"name":"Skills","tokens":9971,"kind":"used"},{"name":"Autocompact buffer","tokens":33000,"kind":"buffer"},{"name":"Free space","tokens":231330,"kind":"free"}],"totalTokens":35670,"maxTokens":300000,"rawMaxTokens":300000,"autocompactSource":"settings","percentage":12,"gridRows":[]}}}
    """

    private func response(requestID: String, line: String = reply) throws -> ControlResponse {
        let message = try #require(StreamJSONDecoder.decode(line: line.replacingOccurrences(of: "REQUEST", with: requestID)))
        guard case .controlResponse(let response) = message else {
            Issue.record("expected a controlResponse message")
            throw CancellationError()
        }
        return response
    }

    private func sessionCapturingLines() -> (HeadlessSession, () -> [String]) {
        let session = HeadlessSession(tabID: UUID(), taskID: UUID())
        var lines: [String] = []
        session.debugLineSink = { lines.append($0) }
        return (session, { lines })
    }

    private func requestID(in line: String) throws -> String {
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue)
        return try #require(object["request_id"]?.stringValue)
    }

    // MARK: - Parser

    @Test func parsesEveryCategoryAndTheTotals() throws {
        let breakdown = try #require(ContextUsageBreakdown(payload: response(requestID: "r1").payload))

        #expect(breakdown.categories.count == 7)
        #expect(breakdown.categories[0] == .init(name: "System prompt", tokens: 2145, kind: "used", isDeferred: false))
        #expect(breakdown.totalTokens == 35670)
        #expect(breakdown.maxTokens == 300_000)
    }

    @Test func displaysNeitherFreeSpaceNorDeferredTools() throws {
        let breakdown = try #require(ContextUsageBreakdown(payload: response(requestID: "r1").payload))

        #expect(breakdown.displayedCategories.map(\.name) == [
            "System prompt", "System tools", "Memory files", "Skills", "Autocompact buffer"
        ])
    }

    @Test func skipsMalformedCategoriesAndKeepsTheRest() throws {
        let payload: [String: JSONValue] = [
            "categories": .array([
                .object(["name": .string("Messages"), "tokens": .number(120), "somethingNew": .bool(true)]),
                .object(["name": .string("No tokens")]),
                .string("not an object")
            ])
        ]

        let breakdown = try #require(ContextUsageBreakdown(payload: payload))

        #expect(breakdown.categories == [.init(name: "Messages", tokens: 120, kind: nil, isDeferred: false)])
        #expect(breakdown.totalTokens == nil)
    }

    @Test func aPayloadWithNoCategoriesIsNoBreakdown() {
        #expect(ContextUsageBreakdown(payload: [:]) == nil)
        #expect(ContextUsageBreakdown(payload: ["categories": .array([])]) == nil)
        #expect(ContextUsageBreakdown(payload: ["categories": .string("nope")]) == nil)
    }

    @Test func encodesASummaryRequest() throws {
        let line = try #require(StreamJSONEncoder.getContextUsage(requestID: "plume-9"))
        let object = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue)

        #expect(object["type"]?.stringValue == "control_request")
        #expect(object["request_id"]?.stringValue == "plume-9")
        let request = try #require(object["request"]?.objectValue)
        #expect(request["subtype"]?.stringValue == "get_context_usage")
        #expect(request["detail"]?.stringValue == "summary")
    }

    // MARK: - Correlation

    @Test func theReplyToTheRequestSetsTheBreakdown() throws {
        let (session, lines) = sessionCapturingLines()

        session.requestContextUsage()
        let id = try requestID(in: try #require(lines().last))
        session.handle(.controlResponse(try response(requestID: id)))

        #expect(session.contextBreakdown?.totalTokens == 35670)
    }

    @Test func aReplyToAnUnknownRequestIsIgnored() throws {
        let (session, _) = sessionCapturingLines()

        session.requestContextUsage()
        session.handle(.controlResponse(try response(requestID: "someone-else")))

        #expect(session.contextBreakdown == nil)
    }

    @Test func aReplyIsAppliedOnlyOnce() throws {
        let (session, lines) = sessionCapturingLines()
        session.requestContextUsage()
        let id = try requestID(in: try #require(lines().last))
        session.handle(.controlResponse(try response(requestID: id)))

        session.handle(.controlResponse(ControlResponse(requestID: id, subtype: "error", payload: [:], errorMessage: "late")))

        #expect(session.contextBreakdown != nil)
    }

    @Test func anErrorReplyClearsTheCachedBreakdown() throws {
        let (session, lines) = sessionCapturingLines()
        session.requestContextUsage()
        session.handle(.controlResponse(try response(requestID: requestID(in: try #require(lines().last)))))

        session.requestContextUsage()
        let second = try requestID(in: try #require(lines().last))
        session.handle(.controlResponse(ControlResponse(
            requestID: second,
            subtype: "error",
            payload: [:],
            errorMessage: "Unknown subtype: get_context_usage"
        )))

        #expect(session.contextBreakdown == nil)
    }

    @Test func aReplyInAnUnexpectedShapeShowsNoBreakdown() throws {
        let (session, lines) = sessionCapturingLines()

        session.requestContextUsage()
        let id = try requestID(in: try #require(lines().last))
        session.handle(.controlResponse(ControlResponse(
            requestID: id,
            subtype: "success",
            payload: ["somethingElse": .number(1)],
            errorMessage: nil
        )))

        #expect(session.contextBreakdown == nil)
    }
}
