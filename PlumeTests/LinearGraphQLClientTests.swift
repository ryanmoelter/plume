import Foundation
import Synchronization
import Testing
@testable import Plume

/// Serves canned responses to a session built on it. Each test makes its own
/// handler key by host path, so suites running in parallel do not share state.
final class LinearStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the stub handler is process-global.
@Suite(.serialized)
struct LinearGraphQLClientTests {
    private let viewerBody = Data("""
        {"data":{"viewer":{"name":"R","displayName":"ryan"},
        "organization":{"id":"o","name":"Plume","urlKey":"plume"}}}
        """.utf8)

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinearStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func client(
        key: String? = "lin_api_key",
        onRateLimit: @escaping @Sendable (LinearRateLimit) -> Void = { _ in }
    ) -> LinearGraphQLClient {
        LinearGraphQLClient(apiKey: { key }, session: makeSession(), onRateLimit: onRateLimit)
    }

    @Test func sendsKeyWithoutBearerAndJSONBody() async throws {
        let captured = Mutex<URLRequest?>(nil)
        LinearStubProtocol.handler = { request in
            captured.withLock { $0 = request }
            return .init(status: 200, headers: [:], body: viewerBody)
        }
        let account = try await client().fetchViewer()
        #expect(account.orgID == "o")
        let request = try #require(captured.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.linear.app/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "lin_api_key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 20)
    }

    @Test func missingKeyIsUnauthorizedWithoutARequest() async {
        let called = Mutex(false)
        LinearStubProtocol.handler = { _ in
            called.withLock { $0 = true }
            return .init(status: 200, headers: [:], body: viewerBody)
        }
        await #expect(throws: LinearError.unauthorized) { try await client(key: nil).fetchViewer() }
        await #expect(throws: LinearError.unauthorized) { try await client(key: "").fetchViewer() }
        #expect(called.withLock { $0 } == false)
    }

    @Test(arguments: [401, 403])
    func authStatusesAreUnauthorized(_ status: Int) async {
        LinearStubProtocol.handler = { _ in .init(status: status, headers: [:], body: Data()) }
        await #expect(throws: LinearError.unauthorized) { try await client().fetchViewer() }
    }

    @Test func status429UsesResetHeader() async {
        LinearStubProtocol.handler = { _ in
            .init(status: 429, headers: ["X-RateLimit-Requests-Reset": "1700000000000"], body: Data())
        }
        await #expect(throws: LinearError.rateLimited(until: Date(timeIntervalSince1970: 1_700_000_000))) {
            try await client().fetchViewer()
        }
    }

    @Test func status429WithoutHeaderFallsBackToAMinute() async throws {
        LinearStubProtocol.handler = { _ in .init(status: 429, headers: [:], body: Data()) }
        let before = Date()
        do {
            _ = try await client().fetchViewer()
            Issue.record("expected a throw")
        } catch LinearError.rateLimited(let until) {
            let delta = until.timeIntervalSince(before)
            #expect(delta > 55 && delta < 65)
        }
    }

    @Test func otherStatusesFail() async {
        LinearStubProtocol.handler = { _ in .init(status: 500, headers: [:], body: Data()) }
        await #expect(throws: LinearError.failed("Linear returned HTTP 500.")) {
            try await client().fetchViewer()
        }
    }

    @Test func surfacesRateLimitHeaders() async throws {
        LinearStubProtocol.handler = { _ in
            .init(status: 200, headers: [
                "X-RateLimit-Requests-Limit": "1500",
                "X-RateLimit-Requests-Remaining": "1499",
                "X-RateLimit-Requests-Reset": "1700000000000",
            ], body: viewerBody)
        }
        let seen = Mutex<[LinearRateLimit]>([])
        _ = try await client(onRateLimit: { limit in seen.withLock { $0.append(limit) } }).fetchViewer()
        #expect(seen.withLock { $0 } == [
            LinearRateLimit(limit: 1500, remaining: 1499, resetAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])
    }

    @Test func incompleteRateLimitHeadersAreIgnored() async throws {
        LinearStubProtocol.handler = { _ in
            .init(status: 200, headers: ["X-RateLimit-Requests-Limit": "1500"], body: viewerBody)
        }
        let seen = Mutex(0)
        _ = try await client(onRateLimit: { _ in seen.withLock { $0 += 1 } }).fetchViewer()
        #expect(seen.withLock { $0 } == 0)
    }

    @Test func fetchIssuesChunksRequestsAndDedupes() async throws {
        let requests = Mutex(0)
        LinearStubProtocol.handler = { request in
            requests.withLock { $0 += 1 }
            let body = request.httpBodyStreamData()
            let count = body.components(separatedBy: " issue(id:").count - 1
            let fields = (0..<count).map { "\"i\($0)\":null" }.joined(separator: ",")
            return .init(status: 200, headers: [:], body: Data("{\"data\":{\(fields)}}".utf8))
        }
        let ids = (0..<60).map { "P-\($0)" } + ["p-0"]
        let result = try await client().fetchIssues(ids)
        #expect(requests.withLock { $0 } == 2)
        #expect(result.count == 60)
        #expect(result.values.allSatisfy { $0 == .notFound })
    }

    @Test func http400RateLimitedBodyIsRateLimited() async {
        LinearStubProtocol.handler = { _ in
            .init(
                status: 400,
                headers: ["X-RateLimit-Requests-Reset": "1700000000000"],
                body: Data(#"{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}"#.utf8)
            )
        }
        await #expect(throws: LinearError.rateLimited(until: Date(timeIntervalSince1970: 1_700_000_000))) {
            try await client().fetchViewer()
        }
    }

    @Test func http400AuthenticationBodyIsUnauthorized() async {
        LinearStubProtocol.handler = { _ in
            .init(status: 400, headers: [:], body: Data(
                #"{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#.utf8))
        }
        await #expect(throws: LinearError.unauthorized) { try await client().fetchViewer() }
    }

    @Test func http400UsesTheBodysErrorMessage() async {
        LinearStubProtocol.handler = { _ in
            .init(status: 400, headers: [:], body: Data(#"{"errors":[{"message":"Query too complex"}]}"#.utf8))
        }
        await #expect(throws: LinearError.failed("Query too complex")) { try await client().fetchViewer() }
    }

    @Test func http401WithAnUncodedBodyIsStillUnauthorized() async {
        LinearStubProtocol.handler = { _ in
            .init(status: 401, headers: [:], body: Data(#"{"errors":[{"message":"Bad key"}]}"#.utf8))
        }
        await #expect(throws: LinearError.unauthorized) { try await client().fetchViewer() }
    }

    @Test func http400WithOnlyNotFoundAliasesStillAnswers() async throws {
        LinearStubProtocol.handler = { _ in
            .init(status: 400, headers: [:], body: Data("""
                {"data":{"i0":null},
                 "errors":[{"message":"Entity not found: Issue","path":["i0"],"extensions":{"code":"INVALID_INPUT"}}]}
                """.utf8))
        }
        let result = try await client().fetchIssues(["P-1"])
        #expect(result == ["P-1": .notFound])
    }
}

private extension URLRequest {
    func httpBodyStreamData() -> String {
        guard let stream = httpBodyStream else { return String(data: httpBody ?? Data(), encoding: .utf8) ?? "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
