import Foundation
import Darwin
import CryptoKit

/// Private local transport for observing a TUI's owned app server. It never
/// listens on TCP and the containing directory is accessible only by its owner.
nonisolated final class CodexUnixWebSocket: @unchecked Sendable {
    enum Failure: Error { case socket, handshake, closed, frame }
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var closed = false
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.codex-terminal-reader")
    private let writer = DispatchQueue(label: "com.ryanmoelter.Plume.codex-terminal-writer")
    private let events: AsyncStream<String>.Continuation
    let lines: AsyncStream<String>

    init() {
        let pair = AsyncStream<String>.makeStream()
        lines = pair.stream
        events = pair.continuation
    }

    func connect(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try open(path: path); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
        queue.async { [self] in
            defer { close() }
            do {
                var fragments = Data()
                var fragmented = false
                while true {
                    let header = try read(2)
                    let opcode = header[0] & 15
                    let final = header[0] & 128 != 0
                    guard header[0] & 112 == 0, header[1] & 128 == 0 else { throw Failure.frame }
                    var size = UInt64(header[1] & 127)
                    if size == 126 { size = try read(2).reduce(0) { $0 << 8 | UInt64($1) } }
                    if size == 127 { size = try read(8).reduce(0) { $0 << 8 | UInt64($1) } }
                    guard size <= 16 * 1024 * 1024 else { throw Failure.frame }
                    if opcode >= 8 && (!final || size > 125) { throw Failure.frame }
                    let payload = try read(Int(size))
                    switch opcode {
                    case 8: return
                    case 9: guard write(payload, opcode: 10) else { return }
                    case 10: break
                    case 1, 0:
                        guard (opcode == 0 && fragmented) || (opcode == 1 && !fragmented) else { throw Failure.frame }
                        if opcode == 1 { fragments = Data() }
                        fragmented = !final
                        fragments.append(payload)
                        guard fragments.count <= 16 * 1024 * 1024 else { throw Failure.frame }
                        if final {
                            guard let text = String(data: fragments, encoding: .utf8) else { throw Failure.frame }
                            events.yield(text)
                            fragments = Data()
                        }
                    default: throw Failure.frame
                    }
                }
            } catch { }
        }
    }

    func send(_ text: String) -> Bool {
        lock.lock(); let open = descriptor >= 0; lock.unlock()
        guard open else { return false }
        writer.async { [self] in
            if !write(Data(text.utf8), opcode: 1) { close() }
        }
        return true
    }

    func close() {
        lock.lock()
        closed = true
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            // The reader owns the final close. Shutdown wakes recv first;
            // its fd cannot be recycled under an in-flight read.
            queue.async { Darwin.close(fd) }
        }
        events.finish()
    }

    private func open(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.socket }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var writeTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(fd); throw Failure.socket }
        lock.lock()
        guard !closed else { lock.unlock(); Darwin.close(fd); throw Failure.closed }
        descriptor = fd
        lock.unlock()
        do {
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
            guard writeBytes(Data(request.utf8), fd: fd) else { throw Failure.handshake }
            var response = Data()
            while !response.suffix(4).elementsEqual([13, 10, 13, 10]) {
                response.append(try read(1))
                guard response.count < 16_384 else { throw Failure.handshake }
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let text = String(decoding: response, as: UTF8.self)
            guard Self.validHandshake(text, expectedAccept: accept) else { throw Failure.handshake }
            timeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        } catch { close(); throw error }
    }

    static func validHandshake(_ response: String, expectedAccept: String) -> Bool {
        let lines = response.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("HTTP/1.1 ") == true,
              lines.first?.split(separator: " ").dropFirst().first == "101" else { return false }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers["sec-websocket-accept"] == expectedAccept &&
            headers["upgrade"]?.lowercased() == "websocket" &&
            headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count), offset = 0
        while offset < count {
            lock.lock(); let fd = descriptor; lock.unlock()
            guard fd >= 0 else { throw Failure.closed }
            let size = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw Failure.closed }
            offset += size
        }
        return data
    }

    private func write(_ payload: Data, opcode: UInt8) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return false }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        var data = Data([128 | opcode])
        let count = payload.count
        if count < 126 { data.append(128 | UInt8(count)) }
        else if count <= 65535 {
            data.append(128 | 126); data.append(UInt8(count >> 8)); data.append(UInt8(count & 255))
        } else {
            data.append(128 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(count) >> shift) & 255)) }
        }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return writeBytes(data, fd: descriptor)
    }

    private func writeBytes(_ data: Data, fd: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let size = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { return false }
            offset += size
        }
        return true
    }
}
