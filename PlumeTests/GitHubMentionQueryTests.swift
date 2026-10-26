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
        let fails: Bool

        init(fails: Bool = false) { self.fails = fails }

        func respond(_ arguments: [String]) throws -> Data {
            let query = arguments.joined(separator: " ")
            calls.withLock { $0.append(query) }
            if fails { throw ForgeError(message: "gh: not logged in") }
            let pull: (Int, String) -> String = { number, title in
                """
                {"number":\(number),"title":"\(title)","url":"https://github.com/o/r/pull/\(number)",\
                "state":"OPEN","isDraft":false,"updatedAt":"2026-10-01T12:00:00Z"}
                """
            }
            let json: String
            if query.contains("search(") {
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

    private func source(_ script: Script, origin: String = "git@github.com:o/r.git") -> PullRequestMentionSource {
        PullRequestMentionSource(
            run: { arguments, _ in try script.respond(arguments) },
            resolve: { _ in ("/repo", RepositoryFacts(originURL: origin, defaultBranch: "main")) }
        )
    }

    private func query(_ typed: String) throws -> MentionQuery {
        try #require(MentionQuery.query(text: typed, caretLocation: (typed as NSString).length, codeRanges: []))
    }

    private func numbers(_ ranked: [RankedMention]) -> [Int] {
        ranked.compactMap { if case .pullRequest(let pull) = $0.candidate { pull.number } else { nil } }
    }

    @Test func theListAnswersAndIsCached() async throws {
        let script = Script()
        let source = source(script)

        #expect(numbers(await source.matches(for: try query("#"), in: "/repo/sub")) == [12])
        #expect(numbers(await source.matches(for: try query("#12"), in: "/repo/sub")) == [12])
        #expect(numbers(await source.matches(for: try query("#add"), in: "/repo/sub")) == [12])
        #expect(script.count == 2)
    }

    @Test func aNumberMissingFromTheListIsLookedUpOnce() async throws {
        let script = Script()
        let source = source(script)

        #expect(numbers(await source.matches(for: try query("#7"), in: "/repo")) == [7])
        #expect(numbers(await source.matches(for: try query("#7"), in: "/repo")) == [7])
        #expect(numbers(await source.matches(for: try query("#99"), in: "/repo")).isEmpty)
        #expect(script.count == 3)
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

    @Test func aFailingGHIsCachedAsNoResults() async throws {
        let script = Script(fails: true)
        let source = source(script)

        #expect(await source.matches(for: try query("#1"), in: "/repo").isEmpty)
        #expect(await source.matches(for: try query("#12"), in: "/repo").isEmpty)
        #expect(script.count == 1)
    }

    @Test func aNonGitHubOriginOrAFileQuerySendsNothing() async throws {
        let script = Script()

        #expect(await source(script, origin: "git@gitlab.com:o/r.git").matches(for: try query("#1"), in: "/repo").isEmpty)
        #expect(await source(script).matches(for: try query("@~/x"), in: "/repo").isEmpty)
        #expect(script.count == 0)
    }
}
