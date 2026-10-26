import Darwin
import Foundation

/// Where the app's CLI socket lives, and the client half of talking to it.
nonisolated enum CLISocket {
    static let fileName = "cli.sock"
    /// The socket's own directory under the data directory, kept mode 0700
    /// so only this user can reach the socket or its lock file.
    static let directoryName = "run"
    /// Exported into every tab, so a `plume` launched from a debug or worktree
    /// build reaches that build rather than the installed app.
    static let pathEnvironmentKey = "PLUME_SOCKET"
    static let tabIDEnvironmentKey = "PLUME_TAB_ID"
    static let taskIDEnvironmentKey = "PLUME_TASK_ID"

    /// `sun_path` holds 104 bytes including the terminator.
    static let maxPathLength = 103

    /// A data directory too deep for `sun_path` binds under a private `/tmp`
    /// directory instead, named by a hash of the preferred path so two such
    /// instances never share a socket.
    static func path(applicationSupport: String, uid: uid_t = getuid()) -> String {
        let preferred = (applicationSupport as NSString).appendingPathComponent("\(directoryName)/\(fileName)")
        if preferred.utf8.count <= maxPathLength { return preferred }
        return fallbackDirectory(uid: uid) + "/cli-\(stableHash(preferred)).sock"
    }

    static func fallbackDirectory(uid: uid_t = getuid()) -> String {
        "/tmp/plume-\(uid)"
    }

    /// The installed app's data directory, which a `plume` run outside any
    /// Plume tab talks to.
    static var releaseApplicationSupport: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Plume"
    }

    static func resolvedPath(environment: [String: String]) -> String {
        if let path = environment[pathEnvironmentKey], !path.isEmpty { return path }
        return path(applicationSupport: releaseApplicationSupport)
    }

    /// FNV-1a, because `Hasher` is seeded per process and the app and the
    /// tool must agree.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Client

    enum ClientError: Error, Equatable, LocalizedError {
        /// Nothing is listening: the app isn't running, or this path is stale.
        case unreachable(String)
        case io(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail): "Plume isn't running (\(detail))"
            case .io(let detail): detail
            case .badResponse: "Plume sent an unreadable reply"
            }
        }
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// A connected, blocking socket with send and receive timeouts, so a
    /// wedged app cannot hang the caller — often a hook that blocks an agent.
    ///
    /// Darwin refuses a connect to a live listener whose backlog is full the
    /// same way it refuses one to a stale socket file, so a refusal is retried
    /// briefly while the file is there.
    static func connect(to path: String, timeout: TimeInterval = 3, retry: Retry = Retry()) throws -> Int32 {
        guard var address = makeAddress(path) else { throw ClientError.unreachable("socket path too long") }
        var attempt = 0
        while true {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ClientError.io("socket: \(errnoText)") }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { return fd }
            let code = errno
            let detail = errnoText
            close(fd)
            let mayBeBusy = (code == ECONNREFUSED || code == EAGAIN) && socketFileExists(at: path)
            guard mayBeBusy, attempt < retry.attempts else { throw ClientError.unreachable(detail) }
            retry.pause(attempt)
            attempt += 1
        }
    }

    struct Retry: Sendable {
        var attempts = 4
        var pause: @Sendable (_ attempt: Int) -> Void = { attempt in usleep(useconds_t(25_000 << attempt)) }
    }

    private static func socketFileExists(at path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
    }

    /// Sends one request and waits for its one reply line.
    static func send(
        _ request: CLIRequest,
        to path: String,
        timeout: TimeInterval = 3,
        retry: Retry = Retry(),
        readReply: (Int32) throws -> Data? = readLine(from:)
    ) throws -> CLIResponse {
        let requestLine = try CLILineCodec.encode(request)
        let fd = try connect(to: path, timeout: timeout, retry: retry)
        defer { close(fd) }
        do {
            try writeAll(requestLine, to: fd)
        } catch {
            // A server that refuses this peer may answer and close before the
            // request is written; its answer explains more than the write error.
            guard let reply = try? readReply(fd) else { throw error }
            return try decodeResponse(reply)
        }
        return try decodeResponse(readReply(fd))
    }

    private static func decodeResponse(_ line: Data?) throws -> CLIResponse {
        guard let line else { throw ClientError.badResponse }
        do {
            return try CLILineCodec.decode(CLIResponse.self, from: line)
        } catch {
            throw ClientError.badResponse
        }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw ClientError.io("write: \(errnoText)")
            }
        }
    }

    /// Nil when the peer closed before a full line arrived.
    static func readLine(from fd: Int32) throws -> Data? {
        var buffer = CLILineCodec.Buffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let line = buffer.nextLine() { return line }
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(Data(chunk[0..<count]))
            } else if count == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                throw ClientError.io("read: \(errnoText)")
            }
        }
    }

    static var errnoText: String {
        String(cString: strerror(errno))
    }
}
