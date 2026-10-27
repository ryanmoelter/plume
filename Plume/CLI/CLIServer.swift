import Darwin
import Foundation
import OSLog

/// The Unix-domain NDJSON server the `plume` tool talks to. One request line,
/// one response line; `docs/cli.md` is the wire reference.
///
/// Only the user who runs Plume may connect: the socket is mode 0600 in a
/// 0700 directory, and every accepted peer's uid is checked with `getpeereid`.
///
/// Everything runs on the main queue, so nothing here may block: sockets are
/// non-blocking, output a client isn't reading waits in a buffer, and a
/// handler that waits on a subprocess awaits it and replies when done.
@MainActor
final class CLIServer {
    static let shared = CLIServer(handler: { await CLICommandHandler.shared.handle($0) })

    struct Limits {
        /// The most unread input, or unsent output, one connection may hold.
        var maxBufferedBytes = 1 << 20
        var idleTimeout: TimeInterval = 30
        /// How long accepting pauses when the process is out of descriptors.
        var acceptRetryDelay: TimeInterval = 0.5
    }

    typealias Handler = @MainActor (CLIRequest) async -> CLIResponse

    private let handler: Handler
    private let allowedUID: uid_t
    private let limits: Limits
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    /// The socket file this server bound, so `stop` never unlinks another's.
    private var socketIdentity: SocketIdentity?
    private var acceptSource: DispatchSourceRead?
    private var isAcceptSuspended = false
    private var connections: [Int32: CLIConnection] = [:]
    private(set) var socketPath: String?

    private struct SocketIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
    }

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

    init(handler: @escaping Handler, allowedUID: uid_t = getuid(), limits: Limits = Limits()) {
        self.handler = handler
        self.allowedUID = allowedUID
        self.limits = limits
    }

    /// A process with no bundle identifier would otherwise bind the installed
    /// app's path.
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
        guard var address = CLISocket.makeAddress(path) else {
            throw ServerError.io("socket path exceeds \(CLISocket.maxPathLength) bytes")
        }
        try prepareDirectory(for: path)
        let lock = try acquireLock(for: path)
        // Whoever bound this path before us has given up the lock, so the
        // socket file is a leftover.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            close(lock)
            throw ServerError.io("socket: \(CLISocket.errnoText)")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var info = stat()
        guard bound == 0, lstat(path, &info) == 0 else {
            let message = CLISocket.errnoText
            close(fd)
            close(lock)
            throw ServerError.io("bind \(path): \(message)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let message = CLISocket.errnoText
            close(fd)
            unlink(path)
            close(lock)
            throw ServerError.io("listen: \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        lockFD = lock
        socketIdentity = SocketIdentity(device: info.st_dev, inode: info.st_ino)
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
        if let socketPath, let socketIdentity {
            var info = stat()
            if lstat(socketPath, &info) == 0, SocketIdentity(device: info.st_dev, inode: info.st_ino) == socketIdentity {
                unlink(socketPath)
            }
        }
        socketPath = nil
        socketIdentity = nil
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    private static func lockPath(for socketPath: String) -> String {
        socketPath + ".lock"
    }

    // MARK: Directory

    /// The socket's directory holds nothing else, so it can be private
    /// whether it sits under `~/Library` or in the shared `/tmp`.
    private func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw ServerError.io("mkdir \(directory): \(CLISocket.errnoText)")
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid()
        else { throw ServerError.unsafeDirectory(directory) }
        chmod(directory, 0o700)
    }

    /// Held for the server's lifetime: only the holder may unlink or bind the
    /// socket path. A refused connect can't tell a dead socket from a live
    /// one whose backlog is full, but a lock dies with its process.
    private func acquireLock(for path: String) throws -> Int32 {
        let lockPath = Self.lockPath(for: path)
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServerError.io("open \(lockPath): \(CLISocket.errnoText)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let message = CLISocket.errnoText
            close(fd)
            if code == EWOULDBLOCK { throw ServerError.alreadyServing(path) }
            throw ServerError.io("lock \(lockPath): \(message)")
        }
        return fd
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
            Self.prepareAcceptedSocket(fd)

            var uid: uid_t = 0
            var gid: gid_t = 0
            let refusal: CLIResponse?
            if getpeereid(fd, &uid, &gid) == 0, uid == allowedUID {
                refusal = nil
            } else {
                Log.app.error("CLI socket refused a peer with uid \(uid, privacy: .public)")
                refusal = .failure("permission denied")
            }

            let connection = CLIConnection(fd: fd, handler: handler, limits: limits, refusal: refusal) { [weak self] fd in
                self?.connections[fd] = nil
            }
            if connection.isOpen { connections[fd] = connection }
        }
    }

    /// Close-on-exec, so a child the app spawns — a shell, an agent — never
    /// holds a client's connection open.
    nonisolated static func prepareAcceptedSocket(_ fd: Int32) {
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
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
}

/// One accepted client. Requests are answered one at a time, in order, on the
/// main actor.
@MainActor
private final class CLIConnection {
    private let fd: Int32
    private let handler: CLIServer.Handler
    private let limits: CLIServer.Limits
    private let onClose: (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Sources not yet through their cancel handler. The descriptor closes
    /// only once none remain.
    private var liveSources = 0
    private var input = CLILineCodec.Buffer()
    private enum Pending {
        case request(Data)
        /// A reply the connection makes itself, queued so it keeps its place
        /// behind requests still being answered.
        case reply(CLIResponse)
    }
    private var pending: [Pending] = []
    private var isAnswering = false
    /// Reading has stopped; the connection finishes once `pending` is answered.
    private var isInputDone = false
    private var output = Data()
    private var idleTimer: DispatchWorkItem?
    /// Reading has stopped; the connection closes once `output` drains.
    private var isFinishing = false
    private var isClosed = false
    private var isDescriptorClosed = false
    /// A refused peer gets one reply, and whatever it sends is discarded. The
    /// connection stays open until the peer closes, so the peer's own write
    /// can't fail before it has read the reply.
    private let isRefused: Bool

    init(
        fd: Int32,
        handler: @escaping CLIServer.Handler,
        limits: CLIServer.Limits,
        refusal: CLIResponse? = nil,
        onClose: @escaping (Int32) -> Void
    ) {
        self.fd = fd
        self.handler = handler
        self.limits = limits
        self.isRefused = refusal != nil
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
        if let refusal { send(refusal) }
    }

    var isOpen: Bool { !isClosed }

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
        guard !isFinishing, !isInputDone else { return }
        resetIdleTimer()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var reachedEnd = false
        while input.count <= limits.maxBufferedBytes {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                if !isRefused { input.append(Data(chunk[0..<count])) }
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
        if isRefused {
            if reachedEnd { close() }
            return
        }
        while let line = input.nextLine() {
            pending.append(.request(line))
        }
        if input.count > limits.maxBufferedBytes {
            pending.append(.reply(.failure("request exceeds \(limits.maxBufferedBytes) bytes")))
            endInput()
        } else if reachedEnd {
            if let line = input.takeRemainder() {
                pending.append(.request(line))
            }
            endInput()
        }
        answerPending()
    }

    private func endInput() {
        isInputDone = true
        readSource?.cancel()
        readSource = nil
    }

    private func answerPending() {
        guard !isAnswering, !isClosed else { return }
        guard !pending.isEmpty else {
            if isInputDone { finish() }
            return
        }
        switch pending.removeFirst() {
        case .reply(let response):
            send(response)
            answerPending()
        case .request(let line):
            isAnswering = true
            Task { @MainActor [self] in
                let response = await respond(to: line)
                isAnswering = false
                send(response)
                answerPending()
            }
        }
    }

    private func respond(to line: Data) async -> CLIResponse {
        let request: CLIRequest
        do {
            request = try CLILineCodec.decode(CLIRequest.self, from: line)
        } catch {
            return .failure("bad request: \(Self.describe(error))")
        }
        return await handler(request)
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
        if isFinishing {
            close()
        } else if isRefused {
            shutdown(fd, SHUT_WR)
        }
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
