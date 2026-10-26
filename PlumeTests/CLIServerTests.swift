import Darwin
import Foundation
import Testing

@testable import Plume

/// `CLIServer` answers `CLISocket.send` over a real socket, keeps the socket
/// private, refuses other users, and replaces only a dead socket.
@MainActor
struct CLIServerTests {
    private func temporarySocketPath() -> String {
        "/tmp/plume-cli-test-\(UUID().uuidString.prefix(8)).sock"
    }

    /// The server answers on the main queue, so the blocking client runs off it.
    private func send(_ request: CLIRequest, to path: String) async throws -> CLIResponse {
        try await Task.detached { try CLISocket.send(request, to: path) }.value
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

    @Test func aMalformedLineGetsAnErrorReply() async throws {
        let server = CLIServer(handler: { _ in .success })
        let path = temporarySocketPath()
        try server.start(path: path)
        defer { server.stop() }

        let reply = try await Task.detached {
            let fd = try CLISocket.connect(to: path)
            defer { close(fd) }
            try CLISocket.writeAll(Data("{\"command\":\"launch\"}\n".utf8), to: fd)
            return try CLISocket.readLine(from: fd)
        }.value
        let response = try CLILineCodec.decode(CLIResponse.self, from: try #require(reply))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown command launch") == true)
    }

    @Test func anOversizedLineGetsAnErrorAndTheConnectionCloses() async throws {
        var handled = false
        var limits = CLIServer.Limits()
        limits.maxBufferedBytes = 64
        let server = CLIServer(handler: { _ in handled = true; return .success }, limits: limits)
        let path = temporarySocketPath()
        try server.start(path: path)
        defer { server.stop() }

        let (reply, afterReply) = try await Task.detached {
            let fd = try CLISocket.connect(to: path)
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
    /// idle close produces; the client's own timeout is far longer.
    @Test func anIdleConnectionIsClosed() async throws {
        var limits = CLIServer.Limits()
        limits.idleTimeout = 0.1
        let server = CLIServer(handler: { _ in .success }, limits: limits)
        let path = temporarySocketPath()
        try server.start(path: path)
        defer { server.stop() }

        let line = try await Task.detached {
            let fd = try CLISocket.connect(to: path, timeout: 10)
            defer { close(fd) }
            return try CLISocket.readLine(from: fd)
        }.value
        #expect(line == nil)
    }

    @Test func aPeerFromAnotherUserIsRefused() async throws {
        var handled = false
        let server = CLIServer(handler: { _ in handled = true; return .success }, allowedUID: getuid() + 1)
        let path = temporarySocketPath()
        try server.start(path: path)
        defer { server.stop() }

        let response = try await send(.ping, to: path)
        #expect(!response.ok)
        #expect(response.error == "permission denied")
        #expect(!handled)
    }

    @Test func aDeadSocketIsReplacedAndALiveOneIsNot() async throws {
        let path = temporarySocketPath()
        let first = CLIServer(handler: { _ in .success })
        try first.start(path: path)
        defer { first.stop() }

        let second = CLIServer(handler: { _ in .success })
        #expect(throws: CLIServer.ServerError.self) { try second.start(path: path) }

        // A socket file left by a crash: bound, then its listener closed.
        let stalePath = temporarySocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(CLISocket.makeAddress(stalePath))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(fd)

        let third = CLIServer(handler: { _ in .success })
        try third.start(path: stalePath)
        defer { third.stop() }
        #expect(try await send(.ping, to: stalePath).ok)
    }

    @Test func stopUnlinksTheSocket() throws {
        let server = CLIServer(handler: { _ in .success })
        let path = temporarySocketPath()
        try server.start(path: path)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aMissingServerIsUnreachable() {
        #expect(throws: CLISocket.ClientError.self) {
            try CLISocket.send(.ping, to: temporarySocketPath())
        }
    }
}
