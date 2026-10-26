import Darwin
import Foundation
import OSLog

/// The Unix-domain NDJSON server the `plume` tool talks to. One request line,
/// one response line; `docs/cli.md` is the wire reference.
///
/// Only the user who runs Plume may connect: the socket is mode 0600, and
/// every accepted peer's uid is checked with `getpeereid`.
@MainActor
final class CLIServer {
    static let shared = CLIServer(handler: { CLICommandHandler.shared.handle($0) })

    private let handler: (CLIRequest) -> CLIResponse
    private let allowedUID: uid_t
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: CLIConnection] = [:]
    private(set) var socketPath: String?

    enum ServerError: Error, LocalizedError {
        case io(String)
        /// Another Plume with the same data directory is already serving.
        case alreadyServing(String)
        case unsafeDirectory(String)

        var errorDescription: String? {
            switch self {
            case .io(let detail): detail
            case .alreadyServing(let path): "another instance is already serving \(path)"
            case .unsafeDirectory(let path): "\(path) is not a private directory owned by this user"
            }
        }
    }

    init(handler: @escaping (CLIRequest) -> CLIResponse, allowedUID: uid_t = getuid()) {
        self.handler = handler
        self.allowedUID = allowedUID
    }

    /// The test host has no bundle identifier and would otherwise bind the
    /// installed app's path.
    func startIfEnabled() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let path = AppPaths.cliSocketPath
        do {
            try start(path: path)
            Log.app.info("CLI socket at \(path, privacy: .public)")
        } catch {
            Log.app.error("CLI server failed to start at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(path: String) throws {
        stop()
        try prepareDirectory(for: path)
        try removeStaleSocket(at: path)

        guard var address = CLISocket.makeAddress(path) else {
            throw ServerError.io("socket path exceeds \(CLISocket.maxPathLength) bytes")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.io("socket: \(CLISocket.errnoText)") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let message = CLISocket.errnoText
            close(fd)
            throw ServerError.io("bind \(path): \(message)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let message = CLISocket.errnoText
            close(fd)
            unlink(path)
            throw ServerError.io("listen: \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        socketPath = path
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for connection in connections.values { connection.close() }
        connections.removeAll()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let socketPath {
            unlink(socketPath)
        }
        socketPath = nil
    }

    // MARK: Directory

    /// The `/tmp` fallback directory is shared ground, so it must be ours and
    /// private before a socket goes in it. The data directory already sits
    /// under the user's private `~/Library`.
    private func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        guard directory == CLISocket.fallbackDirectory(uid: allowedUID) else {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return
        }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw ServerError.io("mkdir \(directory): \(CLISocket.errnoText)")
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == allowedUID
        else { throw ServerError.unsafeDirectory(directory) }
        chmod(directory, 0o700)
    }

    /// A leftover socket from a crashed run refuses connections and is
    /// removed; one that answers belongs to a live instance and is left alone.
    private func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if let fd = try? CLISocket.connect(to: path, timeout: 1) {
            close(fd)
            throw ServerError.alreadyServing(path)
        }
        unlink(path)
    }

    // MARK: Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else {
                Log.app.error("CLI socket refused a peer with uid \(uid, privacy: .public)")
                CLIConnection.reply(.failure("permission denied"), to: fd)
                close(fd)
                continue
            }

            connections[fd] = CLIConnection(fd: fd, handler: handler) { [weak self] fd in
                self?.connections[fd] = nil
            }
        }
    }
}

/// One accepted client. Requests are answered in order, synchronously on the
/// main queue: each is a small model change.
@MainActor
private final class CLIConnection {
    private let fd: Int32
    private let handler: (CLIRequest) -> CLIResponse
    private let onClose: (Int32) -> Void
    private var source: DispatchSourceRead?
    private var buffer = CLILineCodec.Buffer()
    private var isClosed = false

    init(fd: Int32, handler: @escaping (CLIRequest) -> CLIResponse, onClose: @escaping (Int32) -> Void) {
        self.fd = fd
        self.handler = handler
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.resume()
        self.source = source
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
        Darwin.close(fd)
        onClose(fd)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var reachedEnd = false
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(Data(chunk[0..<count]))
            } else if count == 0 {
                reachedEnd = true
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                close()
                return
            }
        }
        while !isClosed, let line = buffer.nextLine() {
            let response: CLIResponse
            do {
                response = handler(try CLILineCodec.decode(CLIRequest.self, from: line))
            } catch {
                response = .failure("bad request: \(Self.describe(error))")
            }
            Self.reply(response, to: fd)
        }
        if reachedEnd { close() }
    }

    private static func describe(_ error: any Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing \(key.stringValue)" }
        return "malformed JSON"
    }

    /// The reply is one short line, so a full send buffer means a client that
    /// stopped reading; it gets a second of patience and is then dropped.
    static func reply(_ response: CLIResponse, to fd: Int32) {
        guard let data = try? CLILineCodec.encode(response) else { return }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&poller, 1, 1000) > 0 else { return }
            } else {
                return
            }
        }
    }
}
