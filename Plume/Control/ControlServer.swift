#if DEBUG
import AppKit
import Darwin
import OSLog

/// A Unix-domain NDJSON server an agent drives a debug Plume through, without
/// Accessibility permission and without touching the user's focus. One socket
/// per instance, named by pid under `AppPaths.controlDirectory`; the path is
/// logged under the `control` category at launch.
///
/// Requests on one connection run in order — a click takes 150 ms, and a
/// driver that sends two expects the second to see the first's effect.
@MainActor
final class ControlServer {
    static let shared = ControlServer(backend: InProcessControlBackend())

    private let backend: any ControlBackend
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: ControlConnection] = [:]
    private(set) var socketPath: String?

    init(backend: any ControlBackend) {
        self.backend = backend
    }

    /// `PLUME_CONTROL=0` opts out. The test host has no bundle identifier and
    /// gets no server, so a test run leaves no socket behind.
    func startIfEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["PLUME_CONTROL"] != "0", Bundle.main.bundleIdentifier != nil else { return }
        let path = AppPaths.controlSocketPath(pid: getpid(), environment: environment)
        do {
            try start(path: path)
            Log.control.info("control socket at \(path, privacy: .public)")
        } catch {
            Log.control.error("control server failed to start at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(path: String) throws {
        stop()
        try prepareDirectory(for: path)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.io("socket: \(Self.errnoText)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw ControlError.io("socket path exceeds \(capacity - 1) bytes")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let message = Self.errnoText
            close(fd)
            throw ControlError.io("bind \(path): \(message)")
        }
        guard listen(fd, 8) == 0 else {
            let message = Self.errnoText
            close(fd)
            unlink(path)
            throw ControlError.io("listen: \(message)")
        }
        chmod(path, 0o600)
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

    /// Plume's own control directory is created private and swept of sockets
    /// whose instance has exited; any other directory (`/tmp`, an override)
    /// is only required to exist.
    private func prepareDirectory(for path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let owned = AppPaths.controlDirectory.path(percentEncoded: false)
        if directory == owned || directory + "/" == owned {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            chmod(directory, 0o700)
            Self.removeStaleSockets(in: directory)
        } else {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    static func removeStaleSockets(in directory: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasSuffix(".sock") {
            guard let pid = Int32(name.dropLast(".sock".count)) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                unlink(directory + "/" + name)
            }
        }
    }

    // MARK: Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let connection = ControlConnection(fd: fd, backend: backend) { [weak self] fd in
                self?.connections[fd] = nil
            }
            connections[fd] = connection
        }
    }

    static var errnoText: String {
        String(cString: strerror(errno))
    }
}

/// One accepted client. Bytes are framed on `\n` the way `HeadlessProcess`
/// frames the CLI's stream, and requests are answered one at a time.
@MainActor
private final class ControlConnection {
    private let fd: Int32
    private let backend: any ControlBackend
    private let onClose: (Int32) -> Void
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var pending: [String] = []
    private var isDraining = false
    private var isClosed = false

    init(fd: Int32, backend: any ControlBackend, onClose: @escaping (Int32) -> Void) {
        self.fd = fd
        self.backend = backend
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
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(chunk, count: Int(count))
            } else if count == 0 {
                close()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                close()
                return
            }
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            pending.append(String(decoding: lineData, as: UTF8.self))
        }
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor [weak self] in
            while let self, !self.isClosed, !self.pending.isEmpty {
                let line = self.pending.removeFirst()
                let response = await ControlDispatcher.handle(line: line, backend: self.backend)
                self.write(response.encodedLine())
            }
            self?.isDraining = false
        }
    }

    private func write(_ data: Data) {
        guard !isClosed else { return }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += Int(written)
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                poll(&poller, 1, 1000)
            } else {
                close()
                return
            }
        }
    }
}
#endif
