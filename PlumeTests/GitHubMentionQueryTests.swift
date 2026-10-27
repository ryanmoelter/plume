import Foundation
import Synchronization
import Testing
@testable import Plume

struct GitHubMentionQueryTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let openPull = """
        {"number":12,"title":"Add mentions","url":"https://github.com/o/r/pull/12","state":"OPEN",
         "isDraft":true,"updatedAt":"2026-10-01T12:00:00Z"}
        """

    @Test func theListAsksForFiftyOpenPullRequestsNewestFirst() {
        let request = GitHubMentionQuery.openPullRequests
        #expect(request.query.contains("repository(owner: $owner, name: $name) { nameWithOwner "))
        #expect(request.query.contains("pullRequests(first: 50, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC})"))
        #expect(request.query.contains("number title url state isDraft updatedAt"))
        #expect(request.arguments.suffix(4) == ["-F", "owner={owner}", "-F", "name={repo}"])
    }

    @Test func aNumberLookupNamesThePullRequest() {
        #expect(GitHubMentionQuery.pullRequest(number: 123).query.contains("pullRequest(number: 123) {"))
    }

    @Test func aTitleSearchIsScopedToTheRepository() {
        let request = GitHubMentionQuery.titleSearch("fix \"it\"", nameWithOwner: "o/r")
        #expect(request.query.contains("search(query: $search, type: ISSUE, first: 10)"))
        #expect(request.query.contains("... on PullRequest {"))
        #expect(request.arguments == [
            "api", "graphql", "-f", "query=" + request.query, "-f", #"search=repo:o/r is:pr in:title fix "it""#,
        ])
    }

    @Test func aSearchTermNamingAVariableStaysSearchText() {
        let request = GitHubMentionQuery.titleSearch("$owner fix", nameWithOwner: "o/r")
        #expect(!request.query.contains("$owner"))
        #expect(!request.arguments.contains("-F"))
        #expect(request.arguments.last == "search=repo:o/r is:pr in:title $owner fix")
    }

    @Test func decodesTheList() throws {
        let json = """
            {"data":{"repository":{"nameWithOwner":"o/r","pullRequests":{"nodes":[\(openPull),
             {"number":9,"title":"Bad state","url":"u","state":"WEIRD","isDraft":false,"updatedAt":null}]}}}}
            """
        let list = try GitHubMentionQuery.decodeOpenPullRequests(data(json))
        #expect(list.nameWithOwner == "o/r")
        #expect(list.pulls == [.init(
            number: 12,
            title: "Add mentions",
            url: "https://github.com/o/r/pull/12",
            state: .open,
            isDraft: true,
            updatedAt: Date(timeIntervalSince1970: 1_790_856_000)
        )])
    }

    @Test func decodesAMissingNumberAsNil() throws {
        let json = #"{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"Could not resolve"}]}"#
        #expect(try GitHubMentionQuery.decodePullRequest(data(json)) == nil)
        let found = "{\"data\":{\"repository\":{\"pullRequest\":\(openPull)}}}"
        #expect(try GitHubMentionQuery.decodePullRequest(data(found))?.number == 12)
    }

    @Test func theRelatedListAsksForThreeSearchesInOneRequest() {
        let request = GitHubMentionQuery.relatedPullRequests(nameWithOwner: "o/r")
        #expect(request.query.hasPrefix("query($search0: String!, $search1: String!, $search2: String!) { "))
        #expect(request.query.contains("related0: search(query: $search0, type: ISSUE, first: 10)"))
        #expect(request.query.contains("related2: search(query: $search2"))
        #expect(Array(request.arguments.dropFirst(4)) == [
            "-f", "search0=repo:o/r is:pr is:open author:@me",
            "-f", "search1=repo:o/r is:pr is:open assignee:@me",
            "-f", "search2=repo:o/r is:pr is:open user-review-requested:@me",
        ])
    }

    @Test func decodesTheRelatedListOncePerPullRequestNewestFirst() throws {
        let older = """
            {"number":4,"title":"Older","url":"u4","state":"OPEN","isDraft":false,"updatedAt":"2026-09-01T12:00:00Z"}
            """
        let json = """
            {"data":{"related0":{"nodes":[\(older)]},"related1":{"nodes":[{},\(openPull)]},
             "related2":{"nodes":[\(openPull)]}}}
            """
        #expect(try GitHubMentionQuery.decodeRelatedPullRequests(data(json)).map(\.number) == [12, 4])
    }

    @Test func aSearchSkipsResultsThatAreNotPullRequests() throws {
        let json = "{\"data\":{\"search\":{\"nodes\":[{},\(openPull)]}}}"
        #expect(try GitHubMentionQuery.decodeSearch(data(json)).map(\.number) == [12])
    }
}

/// The source against a scripted `gh`: which requests it sends for each
/// query shape, and what it caches.
struct PullRequestMentionSourceTests {
    private final class Script: Sendable {
        let calls = Mutex<[String]>([])
        let fails: Mutex<Bool>

        init(fails: Bool = false) { self.fails = Mutex(fails) }

        func respond(_ arguments: [String]) throws -> Data {
            let query = arguments.joined(separator: " ")
            calls.withLock { $0.append(query) }
            if fails.withLock({ $0 }) { throw ForgeError(message: "gh: not logged in") }
            let pull: (Int, String) -> String = { number, title in
                """
                {"number":\(number),"title":"\(title)","url":"https://github.com/o/r/pull/\(number)",\
                "state":"OPEN","isDraft":false,"updatedAt":"2026-10-01T12:00:00Z"}
                """
            }
            let json: String
            if query.contains("related0:") {
                json = "{\"data\":{\"related0\":{\"nodes\":[\(pull(5, "Mine"))]},\"related1\":{\"nodes\":[]},\"related2\":null}}"
            } else if query.contains("search(") {
                json = "{\"data\":{\"search\":{\"nodes\":[\(pull(3, "Old layout fix"))]}}}"
            } else if query.contains("pullRequest(number: 7)") {
                json = "{\"data\":{\"repository\":{\"pullRequest\":\(pull(7, "Closed long ago"))}}}"
            } else if query.contains("pullRequest(number:") {
                json = #"{"data":{"repository":{"pullRequest":null}}}"#
            } else {
                json = """
                    {"data":{"repository":{"nameWithOwner":"o/r","pullRequests":{"nodes":[\(pull(12, "Add mentions"))]}}}}
                    """
            }
            return Data(json.utf8)
        }

        var count: Int { calls.withLock { $0.count } }
    }

    private func source(
        _ script: Script,
        origin: String = "git@github.com:o/r.git",
        clock: Clock? = nil
    ) -> PullRequestMentionSource {
        PullRequestMentionSource(
            run: { arguments, _ in try script.respond(arguments) },
            resolve: { _ in ("/repo", RepositoryFacts(originURL: origin, defaultBranch: "main")) },
            now: { clock?.now.withLock { $0 } ?? Date() }
        )
    }

    private final class Clock: Sendable {
        let now = Mutex(Date(timeIntervalSince1970: 0))
    }

    private func query(_ typed: String) throws -> MentionQuery {
        try #require(MentionQuery.query(text: typed, caretLocation: (typed as NSString).length))
    }

    private func numbers(_ ranked: [RankedMention]) -> [Int] {
        ranked.compactMap { if case .pullRequest(let pull) = $0.candidate { pull.number } else { nil } }
    }

    @Test func theListAnswersAndIsCached() async throws {
        let script = Script()
        let source = source(script)

        #expect(numbers(await source.matches(for: try query("#12"), in: "/repo/sub")) == [12])
        #expect(numbers(await source.matches(for: try query("#ad"), in: "/repo/sub")) == [12])
        #expect(script.count == 1)
    }

    @Test func anEmptyQueryListsOnlyTheViewersPullRequestsAndCachesThem() async throws {
        let script = Script()
        let source = source(script)

        #expect(numbers(await source.matches(for: try query("#"), in: "/repo")) == [5])
        #expect(numbers(await source.matches(for: try query("@pr:"), in: "/repo")) == [5])
        #expect(script.count == 2)
        #expect(script.calls.withLock { $0.last?.contains("related0:") } == true)
    }

    @Test func aNumberIsFoundForTheResolver() async throws {
        let script = Script()
        let source = source(script)

        #expect(await source.pullRequest(number: 12, in: "/repo")?.title == "Add mentions")
        #expect(await source.pullRequest(number: 7, in: "/repo")?.title == "Closed long ago")
        #expect(await source.pullRequest(number: 99, in: "/repo") == nil)
        #expect(await source.pullRequest(number: 99, in: "/repo") == nil)
        #expect(script.count == 3)
    }

    @Test func aNumberMissingFromTheListIsLookedUpOnce() async throws {
        let script = Script()
        let source = source(script)

        #expect(numbers(await source.matches(for: try query("#7"), in: "/repo")) == [7])
        #expect(numbers(await source.matches(for: try query("#7"), in: "/repo")) == [7])
        #expect(numbers(await source.matches(for: try query("#99"), in: "/repo")).isEmpty)
        #expect(script.count == 3)
    }

    @Test func aSignedNumberIsNotLookedUp() async throws {
        let script = Script()
        let source = source(script)

        _ = await source.matches(for: try query("#-5"), in: "/repo")
        _ = await source.matches(for: try query("#+5"), in: "/repo")
        #expect(script.calls.withLock { $0.allSatisfy { !$0.contains("pullRequest(number:") } })
        #expect(PullRequestMentionSource.number(in: "-5") == nil)
        #expect(PullRequestMentionSource.number(in: "5") == 5)
    }

    @Test func aTextQueryOfThreeCharactersSearchesTitles() async throws {
        let script = Script()
        let source = source(script)

        _ = await source.matches(for: try query("#la"), in: "/repo")
        #expect(script.count == 1)
        #expect(numbers(await source.matches(for: try query("#lay"), in: "/repo")) == [3])
        #expect(script.calls.withLock { $0.last?.contains("repo:o/r is:pr in:title lay") } == true)
    }

    /// Parks every caller until opened, and lets a test wait for the first.
    private actor Gate {
        private var isOpen = false
        private var hasWaiter = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            hasWaiter = true
            for watcher in watchers { watcher.resume() }
            watchers = []
            await withCheckedContinuation { waiters.append($0) }
        }

        func firstWaiter() async {
            guard !hasWaiter else { return }
            await withCheckedContinuation { watchers.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @Test func overlappingLookupsKeepEachOthersAnswers() async throws {
        let script = Script()
        let gate = Gate()
        let source = PullRequestMentionSource(
            run: { arguments, _ in
                if arguments.joined().contains("number: 7") { await gate.wait() }
                return try script.respond(arguments)
            },
            resolve: { _ in ("/repo", RepositoryFacts(originURL: "git@github.com:o/r.git", defaultBranch: "main")) }
        )
        let seven = try query("#7")
        let eight = try query("#8")

        let slow = Task { await source.matches(for: seven, in: "/repo") }
        await gate.firstWaiter()
        _ = await source.matches(for: eight, in: "/repo")
        await gate.open()
        _ = await slow.value
        let calls = script.count

        _ = await source.matches(for: seven, in: "/repo")
        _ = await source.matches(for: eight, in: "/repo")
        #expect(script.count == calls)
    }

    @Test func aFailingGHIsRetriedAfterItsBackoff() async throws {
        let script = Script(fails: true)
        let clock = Clock()
        let source = source(script, clock: clock)

        #expect(await source.matches(for: try query("#1"), in: "/repo").isEmpty)
        #expect(await source.matches(for: try query("#12"), in: "/repo").isEmpty)
        #expect(script.count == 1)

        script.fails.withLock { $0 = false }
        clock.now.withLock { $0 = $0.addingTimeInterval(PullRequestMentionSource.failureBackoff + 1) }
        #expect(numbers(await source.matches(for: try query("#12"), in: "/repo")) == [12])
        #expect(script.count == 2)
    }

    @Test func aNonGitHubOriginOrAFileQuerySendsNothing() async throws {
        let script = Script()

        #expect(await source(script, origin: "git@gitlab.com:o/r.git").matches(for: try query("#1"), in: "/repo").isEmpty)
        #expect(await source(script).matches(for: try query("@~/x"), in: "/repo").isEmpty)
        #expect(script.count == 0)
    }
}
