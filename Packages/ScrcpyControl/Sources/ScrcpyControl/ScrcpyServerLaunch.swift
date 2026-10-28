import Foundation

public enum ScrcpyLaunchError: Error, Equatable, CustomStringConvertible {
    case serverJarMissing(path: String)
    case serverJarIsLFSPointer(path: String)
    case serverJarNotAZip(path: String)
    case adbFailed(command: String, status: Int32, output: String)
    case unparsableForwardPort(String)
    case serverExited(status: Int32, output: String)
    case connectTimedOut

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
        }
    }
}

/// Pushes scrcpy-server to a device, forwards a local port to it, and runs it.
public final class ScrcpyServerLaunch: @unchecked Sendable {
    public static let remoteJarPath = "/data/local/tmp/plume-scrcpy-server.jar"

    public let adbURL: URL
    public let serial: String
    public let jarURL: URL
    public let version: String
    /// The socket id the server listens on, as 8 lowercase hex digits.
    public let scid: String

    private let lock = NSLock()
    private var process: Process?
    private var outputTail = OutputTail()
    private var forwardedPort: UInt16?

    public init(adbURL: URL, serial: String, jarURL: URL, version: String) {
        self.adbURL = adbURL
        self.serial = serial
        self.jarURL = jarURL
        self.version = version
        scid = String(format: "%08x", UInt32.random(in: 0..<0x8000_0000))
    }

    public var serverArguments: [String] {
        [
            "CLASSPATH=\(Self.remoteJarPath)", "app_process", "/", "com.genymobile.scrcpy.Server", version,
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "video=true",
            "audio=false",
            "control=true",
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
        try await adb(["push", jarURL.path, Self.remoteJarPath])
        let forwardOutput = try await adb(["forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        guard let port = UInt16(forwardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ScrcpyLaunchError.unparsableForwardPort(forwardOutput)
        }
        lock.withLock { forwardedPort = port }
        do {
            try spawnServer()
        } catch {
            await removeForward()
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

    /// Never blocks: escalates to SIGKILL on a background queue if the shell outlives SIGTERM.
    public func stop() async {
        let running = lock.withLock { () -> Process? in
            defer { process = nil }
            return process
        }
        if let running, running.isRunning {
            running.terminate()
            let pid = running.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning { kill(pid, SIGKILL) }
            }
        }
        await removeForward()
    }

    private func removeForward() async {
        let port = lock.withLock { () -> UInt16? in
            defer { forwardedPort = nil }
            return forwardedPort
        }
        if let port {
            _ = try? await adb(["forward", "--remove", "tcp:\(port)"])
        }
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
        try process.run()
        lock.withLock { self.process = process }
    }

    @discardableResult
    private func adb(_ arguments: [String]) async throws -> String {
        let result = try await ADBCommand.run(adbURL, ["-s", serial] + arguments)
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
    struct Result {
        var status: Int32
        var output: String
    }

    static func run(_ adb: URL, _ arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = adb
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        return await withCheckedContinuation { continuation in
            let reader = pipe.fileHandleForReading
            // Read to EOF off the caller's thread so a chatty command can't fill the pipe and stall.
            DispatchQueue.global().async {
                let output = reader.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: Result(status: process.terminationStatus, output: text))
            }
        }
    }
}
