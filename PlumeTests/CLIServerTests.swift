import Darwin
import Foundation
import Testing

@testable import Plume

/// `CLIServer` answers `CLISocket.send` over a real socket, keeps the socket
/// private, refuses other users, and binds a path only while holding its lock.
///
/// The server answers on the main queue, which the rest of the suite can hold
/// for seconds, so a client waiting on it sets no deadline of its own; the
/// time limit catches a server that never answers.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CLIServerTests {
    /// A socket in its own directory, which the server makes private.
    private func temporarySocketPath() -> String {
        "/tmp/plume-cli-test-\(UUID().uuidString.prefix(8))/cli.sock"
    }

    private func removeDirectory(of path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// The server answers on the main queue, so the blocking client runs off it.
    private func send(_ request: CLIRequest, to path: String) async throws -> CLIResponse {
        try await Task.detached { try CLISocket.send(request, to: path, timeout: nil, replyTimeout: nil) }.value
    }

    private func bindWithoutListening(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(CLISocket.makeAddress(path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        return fd
    }

    @Test func dispatchesARequestToTheHandler() async throws {
        var received: [CLIRequest] = []
        let tabID = UUID()
        let server = CLIServer(handler: { request in
            received.append(request)
            var response = CLIResponse.success
            response.tabID = tabID
            return response
        })
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        var mode = stat()
        #expect(stat(path, &mode) == 0)
        #expect(mode.st_mode & 0o777 == 0o600)

        let request = CLIRequest.newTab(.init(taskID: UUID(), directory: "/tmp", select: true))
        let response = try await send(request, to: path)
        #expect(response.ok)
        #expect(response.tabID == tabID)
        #expect(received == [request])
    }

    @Test func theSocketsDirectoryIsMadePrivate() throws {
        let path = temporarySocketPath()
        let directory = (path as NSString).deletingLastPathComponent
        defer { removeDirectory(of: path) }
        #expect(mkdir(directory, 0o755) == 0)

        let server = CLIServer(handler: { _ in .success })
        try server.start(path: path)
        defer { server.stop() }

        var info = stat()
        #expect(lstat(directory, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
    }

    @Test func aMalformedLineGetsAnErrorReply() async throws {
        let server = CLIServer(handler: { _ in .success })
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let reply = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: nil)
            defer { close(fd) }
            try CLISocket.writeAll(Data("{\"command\":\"launch\"}\n".utf8), to: fd)
            return try CLISocket.readLine(from: fd)
        }.value
        let response = try CLILineCodec.decode(CLIResponse.self, from: try #require(reply))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown command launch") == true)
    }

    @Test func aFinalRequestWithoutANewlineIsAnswered() async throws {
        let server = CLIServer(handler: { _ in .success })
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let reply = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: nil)
            defer { close(fd) }
            try CLISocket.writeAll(Data("{\"command\":\"ping\"}".utf8), to: fd)
            shutdown(fd, SHUT_WR)
            return try CLISocket.readLine(from: fd)
        }.value
        let response = try CLILineCodec.decode(CLIResponse.self, from: try #require(reply))
        #expect(response.ok)
    }

    @Test func anOversizedLineGetsAnErrorAndTheConnectionCloses() async throws {
        var handled = false
        var limits = CLIServer.Limits()
        limits.maxBufferedBytes = 64
        let server = CLIServer(handler: { _ in handled = true; return .success }, limits: limits)
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let (reply, afterReply) = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: nil)
            defer { close(fd) }
            try CLISocket.writeAll(Data(repeating: UInt8(ascii: "x"), count: 200), to: fd)
            return (try CLISocket.readLine(from: fd), try CLISocket.readLine(from: fd))
        }.value
        let response = try CLILineCodec.decode(CLIResponse.self, from: try #require(reply))
        #expect(response.error == "request exceeds 64 bytes")
        #expect(afterReply == nil)
        #expect(!handled)
    }

    /// The client's read returns at end-of-file, which only the server's
    /// idle close produces.
    @Test func anIdleConnectionIsClosed() async throws {
        var limits = CLIServer.Limits()
        limits.idleTimeout = 0.1
        let server = CLIServer(handler: { _ in .success }, limits: limits)
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let line = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: nil)
            defer { close(fd) }
            return try CLISocket.readLine(from: fd)
        }.value
        #expect(line == nil)
    }

    @Test func aPeerFromAnotherUserIsRefused() async throws {
        var handled = false
        let server = CLIServer(handler: { _ in handled = true; return .success }, allowedUID: getuid() + 1)
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let response = try await send(.ping, to: path)
        #expect(!response.ok)
        #expect(response.error == "permission denied")
        #expect(!handled)
    }

    /// The refusal arrives before the peer writes, and the server keeps the
    /// connection open until the peer closes, so the peer's write still lands.
    @Test func aRefusedPeerCanWriteAfterReadingTheRefusal() async throws {
        let server = CLIServer(handler: { _ in .success }, allowedUID: getuid() + 1)
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        defer { server.stop() }

        let (reply, wrote, afterReply) = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: nil)
            defer { close(fd) }
            let reply = try CLISocket.readLine(from: fd)
            let wrote = (try? CLISocket.writeAll(CLILineCodec.encode(CLIRequest.ping), to: fd)) != nil
            return (reply, wrote, try CLISocket.readLine(from: fd))
        }.value
        let response = try CLILineCodec.decode(CLIResponse.self, from: try #require(reply))
        #expect(response.error == "permission denied")
        #expect(wrote)
        #expect(afterReply == nil)
    }

    @Test func aSecondServerOnTheSamePathRefusesAndLeavesTheFirstServing() async throws {
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        let first = CLIServer(handler: { _ in .success })
        try first.start(path: path)
        defer { first.stop() }

        let second = CLIServer(handler: { _ in .success })
        #expect(throws: CLIServer.ServerError.self) { try second.start(path: path) }
        #expect(second.socketPath == nil)
        #expect(try await send(.ping, to: path).ok)

        first.stop()
        try second.start(path: path)
        defer { second.stop() }
        #expect(try await send(.ping, to: path).ok)
    }

    @Test func aLeftoverSocketWithNoLockHolderIsReplaced() async throws {
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        #expect(mkdir((path as NSString).deletingLastPathComponent, 0o700) == 0)
        close(try bindWithoutListening(at: path))

        let server = CLIServer(handler: { _ in .success })
        try server.start(path: path)
        defer { server.stop() }
        #expect(try await send(.ping, to: path).ok)
    }

    @Test func stopUnlinksOnlyItsOwnSocket() throws {
        let server = CLIServer(handler: { _ in .success })
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        try server.start(path: path)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))

        try server.start(path: path)
        unlink(path)
        let replacement = try bindWithoutListening(at: path)
        defer { close(replacement) }
        server.stop()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func aMissingServerIsUnreachable() {
        #expect(throws: CLISocket.ClientError.self) {
            try CLISocket.send(.ping, to: temporarySocketPath())
        }
    }

    @Test func aRefusedConnectIsRetriedWhileTheSocketFileExists() async throws {
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        #expect(mkdir((path as NSString).deletingLastPathComponent, 0o700) == 0)
        let listener = try bindWithoutListening(at: path)
        defer { close(listener) }

        let connected = try await Task.detached {
            var retry = CLISocket.Retry()
            retry.pause = { _ in listen(listener, 1) }
            let fd = try CLISocket.connect(to: path, retry: retry)
            close(fd)
            return true
        }.value
        #expect(connected)

        let stale = temporarySocketPath()
        defer { removeDirectory(of: stale) }
        #expect(mkdir((stale as NSString).deletingLastPathComponent, 0o700) == 0)
        close(try bindWithoutListening(at: stale))
        #expect(throws: CLISocket.ClientError.self) {
            var retry = CLISocket.Retry()
            retry.attempts = 2
            retry.pause = { _ in }
            _ = try CLISocket.connect(to: stale, retry: retry)
        }
    }

    @Test func aReplyThatTimesOutIsReadOnce() throws {
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        #expect(mkdir((path as NSString).deletingLastPathComponent, 0o700) == 0)
        let listener = try bindWithoutListening(at: path)
        defer { close(listener) }
        #expect(listen(listener, 1) == 0)

        var reads = 0
        let error = #expect(throws: CLISocket.ClientError.self) {
            try CLISocket.send(.ping, to: path, replyTimeout: 0.1) { fd in
                reads += 1
                return try CLISocket.readLine(from: fd)
            }
        }
        #expect(reads == 1)
        guard case .noReply = error else {
            Issue.record("expected noReply, got \(String(describing: error))")
            return
        }
    }

    /// A reply slower than the connect deadline still arrives within its own.
    @Test func theReplyWaitsLongerThanTheConnect() async throws {
        let path = temporarySocketPath()
        defer { removeDirectory(of: path) }
        #expect(mkdir((path as NSString).deletingLastPathComponent, 0o700) == 0)
        let listener = try bindWithoutListening(at: path)
        defer { close(listener) }
        #expect(listen(listener, 1) == 0)

        let server = Task.detached {
            let fd = accept(listener, nil, nil)
            defer { close(fd) }
            _ = try CLISocket.readLine(from: fd)
            usleep(300_000)
            try CLISocket.writeAll(CLILineCodec.encode(CLIResponse.success), to: fd)
        }
        let response = try await Task.detached {
            try CLISocket.send(.ping, to: path, timeout: 0.1, replyTimeout: 10)
        }.value
        try await server.value
        #expect(response.ok)
    }
}
