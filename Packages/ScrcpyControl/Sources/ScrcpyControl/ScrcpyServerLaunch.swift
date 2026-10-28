import Foundation

public enum ScrcpyLaunchError: Error, Equatable, CustomStringConvertible {
    case serverJarMissing(path: String)
    case serverJarIsLFSPointer(path: String)
    case serverJarNotAZip(path: String)
    case adbFailed(command: String, status: Int32, output: String)
    case unparsableForwardPort(String)
    case serverExited(status: Int32, output: String)
    case connectTimedOut
    case adbTimedOut(command: String)
    case stopped

    public var description: String {
        switch self {
        case let .serverJarMissing(path):
            "scrcpy-server is missing at \(path)."
        case let .serverJarIsLFSPointer(path):
            "scrcpy-server at \(path) is a Git LFS pointer, not the server. Run `git lfs pull` and rebuild."
        case let .serverJarNotAZip(path):
            "scrcpy-server at \(path) is not a jar."
        case let .adbFailed(command, status, output):
            "`adb \(command)` failed with status \(status): \(output)"
        case let .unparsableForwardPort(output):
            "adb forward printed no port: \(output)"
        case let .serverExited(status, output):
            "scrcpy-server exited with status \(status): \(output)"
        case .connectTimedOut:
            "scrcpy-server did not accept a connection in time."
        case let .adbTimedOut(command):
            "`adb \(command)` did not finish in time."
        case .stopped:
            "The scrcpy connection was closed."
        }
    }
}

/// Pushes scrcpy-server to a device, forwards a local port to it, and runs it.
///
/// `stop()` may run before, during or after `start()`: whatever `start()` has created by then is
/// released, and a `start()` still running afterwards creates nothing more.
public final class ScrcpyServerLaunch: @unchecked Sendable {
    /// How long a stopped server's `adb shell` gets to exit on SIGTERM before SIGKILL.
    static let exitGracePeriod: TimeInterval = 1

    public let adbURL: URL
    public let serial: String
    public let jarURL: URL
    public let version: String
    /// The socket id the server listens on, as 8 lowercase hex digits.
    public let scid: String
    /// Per launch, so two tabs on one device never overwrite each other's jar; `cleanup=true` deletes it.
    public let remoteJarPath: String
    private let pushTimeout: Duration
    private let forwardTimeout: Duration

    private let lock = NSLock()
    private var process: Process?
    private var outputTail = OutputTail()
    private var forwardedPort: UInt16?
    private var stopped = false

    public init(
        adbURL: URL,
        serial: String,
        jarURL: URL,
        version: String,
        pushTimeout: Duration = .seconds(30),
        forwardTimeout: Duration = .seconds(5)
    ) {
        self.adbURL = adbURL
        self.serial = serial
        self.jarURL = jarURL
        self.version = version
        self.pushTimeout = pushTimeout
        self.forwardTimeout = forwardTimeout
        scid = String(format: "%08x", UInt32.random(in: 0..<0x8000_0000))
        remoteJarPath = "/data/local/tmp/plume-scrcpy-server-\(scid).jar"
    }

    public var serverArguments: [String] {
        [
            "CLASSPATH=\(remoteJarPath)", "app_process", "/", "com.genymobile.scrcpy.Server", version,
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "video=true",
            "audio=false",
            "control=true",
            // Plume never reads the device clipboard, so the server shouldn't push every copy.
            "clipboard_autosync=false",
            "video_codec=h264",
            "cleanup=true",
            "send_device_meta=true",
            "send_dummy_byte=true",
            "send_stream_meta=true",
            "send_frame_meta=true",
        ]
    }

    /// Returns the local TCP port forwarded to the server's socket.
    public func start() async throws -> UInt16 {
        try Self.verifyJar(at: jarURL)
        try throwIfStopped()
        try await adb(["push", jarURL.path, remoteJarPath], timeout: pushTimeout)
        try throwIfStopped()
        let forwardOutput: String
        do {
            forwardOutput = try await adb(["forward", "tcp:0", remoteSocket], timeout: forwardTimeout)
        } catch {
            // A cancelled or timed-out forward may still have been created, on a port nobody read.
            await removeForwards(.toRemoteSocket)
            throw error
        }
        guard let port = UInt16(forwardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await removeForwards(.toRemoteSocket)
            throw ScrcpyLaunchError.unparsableForwardPort(forwardOutput)
        }
        let stoppedDuringForward = lock.withLock {
            if !stopped { forwardedPort = port }
            return stopped
        }
        if stoppedDuringForward {
            await removeForwards(.port(port))
            throw ScrcpyLaunchError.stopped
        }
        do {
            try spawnServer()
        } catch {
            await stop()
            throw error
        }
        return port
    }

    /// The server's exit status and recent output, once it has exited.
    public var exitError: ScrcpyLaunchError? {
        lock.withLock {
            guard let process, !process.isRunning else { return nil }
            return .serverExited(status: process.terminationStatus, output: outputTail.text)
        }
    }

    public var recentOutput: String {
        lock.withLock { outputTail.text }
    }

    /// Returns once the forward is gone. The server's shell gets SIGKILL on a background queue if
    /// it outlives SIGTERM.
    public func stop() async {
        await withCheckedContinuation { continuation in
            beginStop { continuation.resume() }
        }
    }

    /// Starts the stop and returns at once; `awaitTerminations()` waits for it.
    public func terminate() {
        beginStop(onForwardRemoved: nil)
    }

    private static let terminations = DispatchGroup()

    /// Blocks until every stop in flight has removed its forward and seen its shell exit, or gives up.
    /// Only for app termination.
    public static func awaitTerminations() {
        _ = terminations.wait(timeout: .now() + exitGracePeriod + 5)
    }

    private func beginStop(onForwardRemoved: (@Sendable () -> Void)?) {
        let (running, port) = lock.withLock { () -> (Process?, UInt16?) in
            stopped = true
            defer {
                process = nil
                forwardedPort = nil
            }
            return (process, forwardedPort)
        }
        guard running != nil || port != nil else {
            onForwardRemoved?()
            return
        }
        Self.terminations.enter()
        let adbURL = adbURL, serial = serial, forwardTimeout = forwardTimeout
        DispatchQueue.global(qos: .utility).async {
            defer { Self.terminations.leave() }
            if let running, running.isRunning { running.terminate() }
            if let port {
                _ = try? ADBCommand.runBlocking(adbURL, ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: forwardTimeout)
            }
            onForwardRemoved?()
            guard let running else { return }
            let deadline = Date().addingTimeInterval(Self.exitGracePeriod)
            while running.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    private var remoteSocket: String { "localabstract:scrcpy_\(scid)" }

    private enum ForwardSelection {
        case port(UInt16)
        /// Whatever `adb forward --list` shows pointing at this launch's socket.
        case toRemoteSocket
    }

    /// Runs on a background queue joined to `terminations` rather than through the cancellable
    /// `ADBCommand.run`, so neither a cancelled connect nor a quit skips it.
    private func removeForwards(_ selection: ForwardSelection) async {
        let adbURL = adbURL, serial = serial, forwardTimeout = forwardTimeout, remoteSocket = remoteSocket
        Self.terminations.enter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                defer {
                    Self.terminations.leave()
                    continuation.resume()
                }
                let locals: [String]
                switch selection {
                case .port(let port):
                    locals = ["tcp:\(port)"]
                case .toRemoteSocket:
                    let listing = try? ADBCommand.runBlocking(adbURL, ["-s", serial, "forward", "--list"], timeout: forwardTimeout)
                    locals = Self.forwards(in: listing?.output ?? "", serial: serial, remote: remoteSocket)
                }
                for local in locals {
                    _ = try? ADBCommand.runBlocking(adbURL, ["-s", serial, "forward", "--remove", local], timeout: forwardTimeout)
                }
            }
        }
    }

    /// The local side of each `adb forward --list` line (`<serial> <local> <remote>`) for this device and remote.
    static func forwards(in listing: String, serial: String, remote: String) -> [String] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[0] == serial, fields[2] == remote else { return nil }
            return String(fields[1])
        }
    }

    private func throwIfStopped() throws {
        if lock.withLock({ stopped }) { throw ScrcpyLaunchError.stopped }
    }

    private func spawnServer() throws {
        let process = Process()
        process.executableURL = adbURL
        process.arguments = ["-s", serial, "shell"] + serverArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.withLock { self.outputTail.append(data) }
        }
        // Spawning under the lock means a concurrent stop() either prevents the spawn or sees the process.
        try lock.withLock {
            guard !stopped else { throw ScrcpyLaunchError.stopped }
            try process.run()
            self.process = process
        }
    }

    @discardableResult
    private func adb(_ arguments: [String], timeout: Duration) async throws -> String {
        let result = try await ADBCommand.run(adbURL, ["-s", serial] + arguments, timeout: timeout)
        guard result.status == 0 else {
            throw ScrcpyLaunchError.adbFailed(command: arguments.joined(separator: " "), status: result.status, output: result.output)
        }
        return result.output
    }

    static let lfsPointerPrefix = Data("version https://git-lfs".utf8)

    public static func verifyJar(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ScrcpyLaunchError.serverJarMissing(path: url.path)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: lfsPointerPrefix.count)) ?? Data()
        if head.starts(with: Data("PK".utf8)) { return }
        if head == lfsPointerPrefix {
            throw ScrcpyLaunchError.serverJarIsLFSPointer(path: url.path)
        }
        throw ScrcpyLaunchError.serverJarNotAZip(path: url.path)
    }
}

/// Keeps the last few KiB of the server's output, for error messages.
private struct OutputTail {
    private static let limit = 4096
    private var data = Data()

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > Self.limit {
            data = Data(data.suffix(Self.limit))
        }
    }

    var text: String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ADBCommand {
    struct Result: Sendable {
        var status: Int32
        var output: String
    }

    /// A timeout throws `ScrcpyLaunchError.adbTimedOut` and cancellation throws `CancellationError`;
    /// both kill the command.
    static func run(_ adb: URL, _ arguments: [String], timeout: Duration) async throws -> Result {
        let invocation = ADBInvocation(adb: adb, arguments: arguments)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.start(timeout: timeout) { continuation.resume(with: $0) }
            }
        } onCancel: {
            invocation.abort(.cancelled)
        }
    }

    /// Blocks the calling thread, so never call it from the main actor.
    static func runBlocking(_ adb: URL, _ arguments: [String], timeout: Duration) throws -> Result {
        let invocation = ADBInvocation(adb: adb, arguments: arguments)
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        invocation.start(timeout: timeout) { outcome in
            box.outcome = outcome
            semaphore.signal()
        }
        semaphore.wait()
        return try box.outcome!.get()
    }

    private final class OutcomeBox: @unchecked Sendable {
        var outcome: Swift.Result<Result, Error>?
    }
}

/// One adb command that finishes exactly once: when it exits, when it times out, or when it is aborted.
private final class ADBInvocation: @unchecked Sendable {
    enum Abort {
        case cancelled
        case timedOut
    }

    private let process = Process()
    private let pipe = Pipe()
    private let commandDescription: String
    private let lock = NSLock()
    private var aborted: Abort?
    private var completion: (@Sendable (Swift.Result<ADBCommand.Result, Error>) -> Void)?

    init(adb: URL, arguments: [String]) {
        process.executableURL = adb
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        commandDescription = arguments.joined(separator: " ")
    }

    func start(timeout: Duration, completion: @escaping @Sendable (Swift.Result<ADBCommand.Result, Error>) -> Void) {
        do {
            try lock.withLock {
                if aborted != nil { throw CancellationError() }
                self.completion = completion
                try process.run()
            }
        } catch {
            lock.withLock { self.completion = nil }
            completion(.failure(error))
            return
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.abort(.timedOut)
        }
        let reader = pipe.fileHandleForReading
        // Read to EOF off the caller's thread so a chatty command can't fill the pipe and stall.
        DispatchQueue.global().async { [self] in
            let output = reader.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.success(ADBCommand.Result(status: process.terminationStatus, output: text)))
        }
    }

    /// Finishes at once rather than waiting for the output to reach EOF, which a forked adb server can hold open.
    func abort(_ reason: Abort) {
        let pending = lock.withLock { () -> Bool in
            guard aborted == nil else { return false }
            aborted = reason
            return completion != nil
        }
        guard pending else { return }
        if process.isRunning {
            process.terminate()
            let process = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        switch reason {
        case .cancelled: finish(.failure(CancellationError()))
        case .timedOut: finish(.failure(ScrcpyLaunchError.adbTimedOut(command: commandDescription)))
        }
    }

    private func finish(_ outcome: Swift.Result<ADBCommand.Result, Error>) {
        let completion = lock.withLock { () -> (@Sendable (Swift.Result<ADBCommand.Result, Error>) -> Void)? in
            defer { self.completion = nil }
            return self.completion
        }
        completion?(outcome)
    }
}
