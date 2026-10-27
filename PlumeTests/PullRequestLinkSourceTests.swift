import Foundation
import Synchronization
import Testing
@testable import Plume

/// `PullRequestLinkSource` against a scripted `gh`: one aliased query per
/// repository, definitive misses cached, transient failures retried.
struct PullRequestLinkSourceTests {
    private final class Script: Sendable {
        private let state = Mutex<(replies: [Result<Data, ForgeError>], calls: [[String]])>(([], []))

        init(_ replies: [Result<Data, ForgeError>]) {
            state.withLock { $0.replies = replies }
        }

        var calls: [[String]] { state.withLock { $0.calls } }

        func run(_ arguments: [String]) throws -> Data {
            let reply = state.withLock { state -> Result<Data, ForgeError> in
                state.calls.append(arguments)
                return state.replies.isEmpty ? .failure(ForgeError(message: "unscripted")) : state.replies.removeFirst()
            }
            return try reply.get()
        }
    }

    private final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 0))
        var now: Date { time.withLock { $0 } }
        func advance(by interval: TimeInterval) { time.withLock { $0 += interval } }
    }

    private func source(_ script: Script, clock: Clock = Clock()) -> PullRequestLinkSource {
        PullRequestLinkSource(run: { try script.run($0) }, sleep: { _ in }, now: { clock.now })
    }

    private func body(_ pulls: [Int: (title: String, state: String)?]) -> Result<Data, ForgeError> {
        var repository: [String: Any] = [:]
        for (number, pull) in pulls {
            repository["p\(number)"] = pull.map { ["number": number, "title": $0.title, "url": "u", "state": $0.state, "isDraft": false] as [String: Any] } ?? NSNull()
        }
        return .success(try! JSONSerialization.data(withJSONObject: ["data": ["repository": repository]]))
    }

    private let p12 = PullRequestLinkSource.Key(owner: "Ryan", repo: "Plume", number: 12)
    private let p13 = PullRequestLinkSource.Key(owner: "ryan", repo: "plume", number: 13)

    @Test func oneRepositoryIsOneAliasedQueryWithItsNameAsVariables() async throws {
        let script = Script([body([12: ("Twelve", "OPEN"), 13: ("Thirteen", "MERGED")])])
        let answers = await source(script).lookUp([p12, p13])
        #expect(answers[p12] == .found(.init(number: 12, title: "Twelve", state: .open, isDraft: false)))
        #expect(answers[p13] == .found(.init(number: 13, title: "Thirteen", state: .merged, isDraft: false)))
        let call = try #require(script.calls.first)
        #expect(script.calls.count == 1)
        #expect(call.prefix(2) == ["api", "graphql"])
        #expect(call.contains("owner=ryan"))
        #expect(call.contains("name=plume"))
        let query = try #require(call.first { $0.hasPrefix("query=") })
        #expect(query.contains("p12: pullRequest(number: 12)"))
        #expect(query.contains("p13: pullRequest(number: 13)"))
    }

    @Test func eachRepositoryGetsItsOwnQuery() async {
        let other = PullRequestLinkSource.Key(owner: "o", repo: "r", number: 1)
        let script = Script([body([1: ("One", "OPEN")]), body([12: ("Twelve", "OPEN")])])
        let answers = await source(script).lookUp([p12, other])
        #expect(script.calls.count == 2)
        #expect(answers.count == 2)
    }

    @Test func anAnswerIsCachedUntilItsLifetimeEnds() async {
        let clock = Clock()
        let script = Script([body([12: ("Twelve", "OPEN")]), body([12: ("Renamed", "OPEN")])])
        let source = source(script, clock: clock)
        _ = await source.lookUp([p12])
        _ = await source.lookUp([p12])
        #expect(script.calls.count == 1)
        clock.advance(by: PullRequestLinkSource.openLifetime)
        let answers = await source.lookUp([p12])
        #expect(script.calls.count == 2)
        #expect(answers[p12] == .found(.init(number: 12, title: "Renamed", state: .open, isDraft: false)))
    }

    @Test func aMergedPullRequestOutlivesAnOpenOne() async {
        let clock = Clock()
        let script = Script([body([12: ("Twelve", "MERGED")])])
        let source = source(script, clock: clock)
        _ = await source.lookUp([p12])
        clock.advance(by: PullRequestLinkSource.openLifetime)
        _ = await source.lookUp([p12])
        #expect(script.calls.count == 1)
    }

    @Test func aMissingNumberIsCachedAndTheRestAskedAgain() async throws {
        let script = Script([
            .failure(ForgeError(message: "GraphQL: Could not resolve to a PullRequest with the number of 13. (repository.p13)")),
            body([12: ("Twelve", "OPEN")])
        ])
        let source = source(script)
        let answers = await source.lookUp([p12, p13])
        #expect(answers[p13] == .missing)
        #expect(answers[p12] == .found(.init(number: 12, title: "Twelve", state: .open, isDraft: false)))
        let retry = try #require(script.calls.last?.first { $0.hasPrefix("query=") })
        #expect(!retry.contains("p13"))
        _ = await source.lookUp([p13])
        #expect(script.calls.count == 2)
    }

    @Test func aMissingRepositoryMissesEveryNumber() async {
        let script = Script([.failure(ForgeError(message: "GraphQL: Could not resolve to a Repository with the name 'ryan/plume'. (repository)"))])
        let answers = await source(script).lookUp([p12, p13])
        #expect(answers[p12] == .missing)
        #expect(answers[p13] == .missing)
        #expect(script.calls.count == 1)
    }

    @Test func aTransientFailureIsRetried() async {
        let script = Script([.failure(ForgeError(message: "gh timed out", kind: .timedOut)), body([12: ("Twelve", "OPEN")])])
        let answers = await source(script).lookUp([p12])
        #expect(answers[p12] != nil)
        #expect(script.calls.count == 2)
    }

    @Test func failuresPastTheRetriesAnswerNothingAndCacheNothing() async {
        let failures = Array(repeating: Result<Data, ForgeError>.failure(ForgeError(message: "offline")), count: PullRequestLinkSource.retryDelays.count + 1)
        let script = Script(failures + [body([12: ("Twelve", "OPEN")])])
        let source = source(script)
        #expect(await source.lookUp([p12]).isEmpty)
        #expect(script.calls.count == PullRequestLinkSource.retryDelays.count + 1)
        #expect(await source.lookUp([p12])[p12] != nil)
    }
}
