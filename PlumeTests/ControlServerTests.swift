import Darwin
import CoreGraphics
import Foundation
import Testing

@testable import Plume

/// The socket server answers a raw Unix-domain client one NDJSON line per
/// request, keeps its socket private, and cleans up after itself.
@MainActor
struct ControlServerTests {
    private func temporarySocketPath() -> String {
        "/tmp/plume-control-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func answersAListRequestOverTheSocket() async throws {
        let backend = FakeControlBackend()
        backend.listResult = [
            ControlDescription(id: "send", index: 0, isEnabled: true, frame: Rect(.zero), hasInvoke: true, hasSetValue: false)
        ]
        let server = ControlServer(backend: backend)
        let path = temporarySocketPath()
        try server.start(path: path)
        defer { server.stop() }

        var mode = stat()
        #expect(stat(path, &mode) == 0)
        #expect(mode.st_mode & 0o777 == 0o600)

        let reply = try await roundTrip(path: path, line: #"{"id":"1","command":"list"}"# + "\n")
        let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        #expect(json?["ok"] as? Bool == true)
        #expect(((json?["result"] as? [[String: Any]])?.first?["id"] as? String) == "send")
        #expect(backend.calls == ["list"])
    }

    @Test func stopUnlinksTheSocket() throws {
        let server = ControlServer(backend: FakeControlBackend())
        let path = temporarySocketPath()
        try server.start(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(server.socketPath == nil)
    }

    @Test func staleSocketsOfDeadInstancesAreRemoved() throws {
        let directory = "/tmp/plume-control-test-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let stale = directory + "/999999.sock"
        let live = directory + "/\(getpid()).sock"
        let unrelated = directory + "/notes.txt"
        for file in [stale, live, unrelated] {
            #expect(FileManager.default.createFile(atPath: file, contents: nil))
        }
        ControlServer.removeStaleSockets(in: directory)
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(FileManager.default.fileExists(atPath: live))
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }

    /// The server reads and answers on the main queue, so the client runs on
    /// a detached task; blocking the main thread would deadlock the exchange.
    private func roundTrip(path: String, line: String) async throws -> String {
        try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw ControlError.io("connect: \(String(cString: strerror(errno)))") }
            let payload = Array(line.utf8)
            guard write(fd, payload, payload.count) == payload.count else { throw ControlError.io("short write") }
            var received = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !received.contains(0x0A) {
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { throw ControlError.io("connection closed") }
                received.append(chunk, count: Int(count))
            }
            return String(decoding: received.prefix(while: { $0 != 0x0A }), as: UTF8.self)
        }.value
    }
}
