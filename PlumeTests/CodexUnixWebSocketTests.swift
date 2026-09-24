import Foundation
import Darwin
import CryptoKit
import Testing
@testable import Plume

nonisolated private final class LocalWebSocketServer: @unchecked Sendable {
    let path = "/private/tmp/plume-ws-test-" + UUID().uuidString
    let connected: AsyncStream<Void>
    private let connectedSignal: AsyncStream<Void>.Continuation
    private let fd: Int32

    init(completeHandshake: Bool) throws {
        let pair = AsyncStream<Void>.makeStream()
        connected = pair.stream; connectedSignal = pair.continuation
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { throw CodexUnixWebSocket.Failure.socket }
        DispatchQueue.global().async { [self] in
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            defer { Darwin.close(peer); connectedSignal.finish() }
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var request = Data(), byte: UInt8 = 0
            while !request.suffix(4).elementsEqual([13,10,13,10]) {
                guard Darwin.recv(peer, &byte, 1, 0) == 1 else { return }
                request.append(byte)
            }
            connectedSignal.yield(())
            guard completeHandshake else {
                _ = Darwin.recv(peer, &byte, 1, 0)
                return
            }
            let text = String(decoding: request, as: UTF8.self)
            guard let keyLine = text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }) else { return }
            let key = keyLine.dropFirst("Sec-WebSocket-Key:".count).trimmingCharacters(in: .whitespaces)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            // Deliberately fragment the socket writes as well as the message,
            // with a ping between continuation frames.
            let bytes = Array(response.utf8) + [0x01, 2, 104, 101, 0x89, 1, 120, 0x80, 3, 108, 108, 111]
            for value in bytes {
                var byte = value
                guard Darwin.send(peer, &byte, 1, 0) == 1 else { return }
            }
            // Wait for the pong / shutdown, avoiding a premature close.
            var scratch = [UInt8](repeating: 0, count: 64)
            _ = Darwin.recv(peer, &scratch, scratch.count, 0)
        }
    }

    deinit { Darwin.close(fd); unlink(path) }
}

struct CodexUnixWebSocketTests {
    @Test func validatesAcceptWithoutCaseFoldingOrMissingUpgradeHeaders() {
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: aB==\r\n\r\n"
        #expect(CodexUnixWebSocket.validHandshake(response, expectedAccept: "aB=="))
        #expect(!CodexUnixWebSocket.validHandshake(response, expectedAccept: "ab=="))
        #expect(!CodexUnixWebSocket.validHandshake(response.replacingOccurrences(of: "Upgrade: websocket\r\n", with: ""), expectedAccept: "aB=="))
    }

    @Test func readsPartialFramesAndInterleavedPing() async throws {
        let server = try LocalWebSocketServer(completeHandshake: true)
        let client = CodexUnixWebSocket()
        defer { client.close() }
        try await client.connect(path: server.path)
        var iterator = client.lines.makeAsyncIterator()
        #expect(await iterator.next() == "hello")
    }

    @Test func closingDuringHandshakePreventsConnectionPublication() async throws {
        let server = try LocalWebSocketServer(completeHandshake: false)
        let client = CodexUnixWebSocket()
        let connecting = Task { try await client.connect(path: server.path) }
        var iterator = server.connected.makeAsyncIterator()
        _ = await iterator.next()
        client.close()
        do {
            try await connecting.value
            Issue.record("Closed handshake unexpectedly succeeded")
        } catch { }
        #expect(!client.send("{}"))
    }
}
