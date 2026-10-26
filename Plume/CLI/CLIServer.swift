import Darwin
import Foundation
import OSLog

/// The Unix-domain NDJSON server the `plume` tool talks to. One request line,
/// one response line; `docs/cli.md` is the wire reference.
///
/// Only the user who runs Plume may connect: the socket is mode 0600, and
/// every accepted peer's uid is checked with `getpeereid`.
///
/// Everything runs on the main queue, so nothing here may block: sockets are
/// non-blocking, and output a client isn't reading waits in a buffer.
@MainActor
final class CLIServer {
    static let shared = CLIServer(handler: { CLICommandHandler.shared.handle($0) })

    struct Limits {
        /// The most unread input, or unsent output, one connection may hold.
        var maxBufferedBytes = 1 << 20
        var idleTimeout: TimeInterval = 30
        /// How long accepting pauses when the process is out of descriptors.
        var acceptRetryDelay: TimeInterval = 0.5
    }

    private let handler: (CLIRequest) -> CLIResponse
    private let allowedUID: uid_t
    private let limits: Limits
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isAcceptSuspended = false
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

    init(handler: @escaping (CLIRequest) -> CLIResponse, allowedUID: uid_t = getuid(), limits: Limits = Limits()) {
        self.handler = handler
        self.allowedUID = allowedUID
        self.limits = limits
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
        // Closing before the source finishes cancelling would let a reused
        // descriptor number reach this source.
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        if let acceptSource {
            // A suspended source never delivers its cancellation.
            if isAcceptSuspended { acceptSource.resume() }
            acceptSource.cancel()
        }
        acceptSource = nil
        isAcceptSuspended = false
        listenFD = -1
        for connection in connections.values { connection.close() }
        connections.removeAll()
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
        if Self.hasListener(at: path) { throw ServerError.alreadyServing(path) }
        unlink(path)
    }

    /// A non-blocking connect, which a Unix socket answers at once: refused
    /// when nothing listens, and `EAGAIN` when a listener's backlog is full.
    private static func hasListener(at path: String) -> Bool {
        guard var address = CLISocket.makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0 || errno == EAGAIN || errno == EINPROGRESS
    }

    // MARK: Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE:
                    // The pending connection keeps the socket readable, so
                    // returning would refire the source at once, forever.
                    Log.app.error("CLI socket can't accept: out of file descriptors")
                    pauseAccepting()
                    return
                default:
                    return
                }
            }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == allowedUID else {
                Log.app.error("CLI socket refused a peer with uid \(uid, privacy: .public)")
                Self.writeOnce(.failure("permission denied"), to: fd)
                close(fd)
                continue
            }

            connections[fd] = CLIConnection(fd: fd, handler: handler, limits: limits) { [weak self] fd in
                self?.connections[fd] = nil
            }
        }
    }

    private func pauseAccepting() {
        guard let source = acceptSource, !isAcceptSuspended else { return }
        source.suspend()
        isAcceptSuspended = true
        DispatchQueue.main.asyncAfter(deadline: .now() + limits.acceptRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isAcceptSuspended, let source = self.acceptSource else { return }
                self.isAcceptSuspended = false
                source.resume()
            }
        }
    }

    /// One short line into a fresh socket's empty send buffer; if even that
    /// doesn't fit, the peer goes without its explanation.
    private static func writeOnce(_ response: CLIResponse, to fd: Int32) {
        guard let data = try? CLILineCodec.encode(response) else { return }
        var written: Int
        repeat {
            written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        } while written < 0 && errno == EINTR
    }
}

/// One accepted client. Requests are answered in order, synchronously on the
/// main queue: each is a small model change.
@MainActor
private final class CLIConnection {
    private let fd: Int32
    private let handler: (CLIRequest) -> CLIResponse
    private let limits: CLIServer.Limits
    private let onClose: (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Sources not yet through their cancel handler. The descriptor closes
    /// only once none remain.
    private var liveSources = 0
    private var input = CLILineCodec.Buffer()
    private var output = Data()
    private var idleTimer: DispatchWorkItem?
    /// Reading has stopped; the connection closes once `output` drains.
    private var isFinishing = false
    private var isClosed = false
    private var isDescriptorClosed = false

    init(fd: Int32, handler: @escaping (CLIRequest) -> CLIResponse, limits: CLIServer.Limits, onClose: @escaping (Int32) -> Void) {
        self.fd = fd
        self.handler = handler
        self.limits = limits
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.setCancelHandler { [self] in
            MainActor.assumeIsolated { sourceDidCancel() }
        }
        liveSources += 1
        source.resume()
        readSource = source
        resetIdleTimer()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isFinishing = true
        idleTimer?.cancel()
        idleTimer = nil
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        closeDescriptorIfUnused()
        onClose(fd)
    }

    private func sourceDidCancel() {
        liveSources -= 1
        closeDescriptorIfUnused()
    }

    private func closeDescriptorIfUnused() {
        guard isClosed, liveSources == 0, !isDescriptorClosed else { return }
        isDescriptorClosed = true
        Darwin.close(fd)
    }

    /// Stops reading and closes once every reply is sent.
    private func finish() {
        isFinishing = true
        readSource?.cancel()
        readSource = nil
        if output.isEmpty { close() }
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        idleTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + limits.idleTimeout, execute: timer)
    }

    // MARK: Input

    private func readAvailable() {
        guard !isFinishing else { return }
        resetIdleTimer()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var reachedEnd = false
        while input.count <= limits.maxBufferedBytes {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                input.append(Data(chunk[0..<count]))
            } else if count == 0 {
                reachedEnd = true
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                close()
                return
            }
        }
        while let line = input.nextLine() {
            send(respond(to: line))
            if isClosed { return }
        }
        if input.count > limits.maxBufferedBytes {
            send(.failure("request exceeds \(limits.maxBufferedBytes) bytes"))
            finish()
        } else if reachedEnd {
            finish()
        }
    }

    private func respond(to line: Data) -> CLIResponse {
        do {
            return handler(try CLILineCodec.decode(CLIRequest.self, from: line))
        } catch {
            return .failure("bad request: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: any Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing \(key.stringValue)" }
        return "malformed JSON"
    }

    // MARK: Output

    private func send(_ response: CLIResponse) {
        guard !isClosed, let data = try? CLILineCodec.encode(response) else { return }
        output.append(data)
        // A client that keeps sending but never reads.
        guard output.count <= limits.maxBufferedBytes else {
            close()
            return
        }
        flush()
    }

    private func flush() {
        while !output.isEmpty {
            let written = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                output.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                awaitWritable()
                return
            } else {
                close()
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
        if isFinishing { close() }
    }

    private func awaitWritable() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        source.setCancelHandler { [self] in
            MainActor.assumeIsolated { sourceDidCancel() }
        }
        liveSources += 1
        source.resume()
        writeSource = source
    }
}
