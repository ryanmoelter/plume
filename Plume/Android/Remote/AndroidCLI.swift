import Foundation

nonisolated struct AndroidCLIResult: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false

    var succeeded: Bool { status == 0 && !timedOut }

    /// Everything the command printed, for matching messages that may land on either stream.
    var output: String { stdout + "\n" + stderr }

    /// What to show the user when the command failed.
    var failureMessage: String {
        if timedOut { return "The android command did not finish in time." }
        let text = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text ?? "The android command failed with status \(status)."
    }
}

nonisolated struct AndroidCLIError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let notInstalled = AndroidCLIError(message: "The android command-line tool wasn't found.")
}

/// Runs the `android` command-line tool. Behind a protocol so tests never reach Google.
nonisolated protocol AndroidCLIRunning: Sendable {
    /// Throws only when the tool can't be found or spawned. `onOutput` gets each new piece of stdout as it arrives.
    func run(
        _ arguments: [String],
        timeout: Duration,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> AndroidCLIResult
}

extension AndroidCLIRunning {
    func run(_ arguments: [String], timeout: Duration = AndroidCLI.defaultTimeout) async throws -> AndroidCLIResult {
        try await run(arguments, timeout: timeout, onOutput: nil)
    }
}

nonisolated final class AndroidCLI: AndroidCLIRunning, @unchecked Sendable {
    static let shared = AndroidCLI()
    static let defaultTimeout: Duration = .seconds(60)

    static let installURL = URL(string: "https://developer.android.com/tools/agents/android-cli")!

    private static let beginMarker = "__PLUME_ANDROID_CLI_BEGIN__"
    private static let endMarker = "__PLUME_ANDROID_CLI_END__"

    private let lock = NSLock()
    private var cachedLocation: URL?
    private let discover: @Sendable () -> URL?

    init(discover: @escaping @Sendable () -> URL? = AndroidCLI.discover) {
        self.discover = discover
    }

    /// A GUI launch has no shell PATH, so this asks the login shell, then tries the usual install
    /// paths. Only a found tool is cached, so installing one shows up on the next check.
    func locate(refresh: Bool = false) async -> URL? {
        if !refresh, let cached = lock.withLock({ cachedLocation }) { return cached }
        let found = await Task.detached(priority: .userInitiated) { [discover] in discover() }.value
        lock.withLock { cachedLocation = found }
        return found
    }

    func run(
        _ arguments: [String],
        timeout: Duration,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> AndroidCLIResult {
        guard let executable = await locate() else { throw AndroidCLIError.notInstalled }
        var environment = ProcessInfo.processInfo.environment
        if let sdk = await AndroidSDKLocator.locate().sdk {
            environment.merge(sdk.launchEnvironment) { _, sdkValue in sdkValue }
            if let adbDirectory = sdk.adbURL?.deletingLastPathComponent().path {
                environment["PATH"] = [adbDirectory, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
            }
        }
        return try await ChildProcess.run(
            executable: executable.path,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            capturesToFile: Self.leavesDaemon(arguments),
            onOutput: onOutput
        )
    }

    /// `connect` starts a daemon that outlives the command, so its output can't go through pipes.
    private static func leavesDaemon(_ arguments: [String]) -> Bool {
        arguments.starts(with: ["device", "remote", "connect"])
    }

    static func candidatePaths(shellPath: String?, home: String = NSHomeDirectory()) -> [String] {
        [shellPath, "/usr/local/bin/android", "/opt/homebrew/bin/android", home + "/.android/bin/android-cli"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    static func parseShellOutput(_ output: String) -> String? {
        guard let begin = output.range(of: beginMarker),
              let end = output.range(of: endMarker, range: begin.upperBound..<output.endIndex)
        else { return nil }
        let path = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        // An alias or function prints its definition, not a path.
        return path.hasPrefix("/") ? path : nil
    }

    static func discover() -> URL? {
        let script = "echo \(beginMarker); command -v android; echo \(endMarker)"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let shellPath = AndroidSDKLocator.runCapturingOutput(
            executable: shell, arguments: ["-lic", script], timeout: AndroidSDKLocator.loginShellTimeout
        ).flatMap(parseShellOutput)
        return candidatePaths(shellPath: shellPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Spawns a short-lived command and captures both streams. It waits for the child to exit, not for
/// its pipes to close, because `android device remote connect` leaves a daemon behind that may
/// inherit them.
///
/// With `capturesToFile`, the child's stdout and stderr go to one temporary file instead of pipes,
/// so a daemon that inherits them has no pipe to break. Both land in `stdout`, and `onOutput`
/// isn't called.
///
/// The child leads its own process group, since `android` is a wrapper whose `android-cli` child
/// would outlive a signal to the wrapper alone. Only a cancel or a timeout signals the group, so
/// the daemon a finished `connect` leaves behind survives.
nonisolated enum ChildProcess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        capturesToFile: Bool = false,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> AndroidCLIResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runBlocking(
                            executable: executable, arguments: arguments, environment: environment,
                            timeout: timeout, cancellation: cancellation, capturesToFile: capturesToFile, onOutput: onOutput
                        )
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        cancellation: CancellationFlag,
        capturesToFile: Bool,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> AndroidCLIResult {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        var captureFile: (path: String, descriptor: Int32)?
        if capturesToFile {
            var template = Array((NSTemporaryDirectory() + "plume-android-XXXXXX").utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw AndroidCLIError(message: "Couldn't create a temporary file.") }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            // Appending lets the truncate below rewind the daemon's writes too, since it shares this file offset.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_APPEND)
            captureFile = (String(cString: template), descriptor)
            outPipe = [-1, descriptor]
            errPipe = [-1, descriptor]
        } else {
            guard pipe(&outPipe) == 0 else { throw AndroidCLIError(message: "Couldn't create a pipe.") }
            guard pipe(&errPipe) == 0 else {
                outPipe.forEach { close($0) }
                throw AndroidCLIError(message: "Couldn't create a pipe.")
            }
            for descriptor in outPipe + errPipe { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        }
        defer {
            if let captureFile {
                // The daemon keeps the unlinked file open, so its space comes back only by truncating.
                _ = ftruncate(captureFile.descriptor, 0)
                close(captureFile.descriptor)
                unlink(captureFile.path)
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        let readEnds: [Int32]
        if captureFile == nil {
            close(outPipe[1])
            close(errPipe[1])
            readEnds = [outPipe[0], errPipe[0]]
        } else {
            readEnds = []
        }
        defer { readEnds.forEach { close($0) } }
        guard spawnStatus == 0 else {
            throw AndroidCLIError(message: "Couldn't run \(executable): \(String(cString: strerror(spawnStatus)))")
        }
        for descriptor in readEnds { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }

        var stdout = Data()
        var stderr = Data()
        var undelivered = Data()
        var open = [!readEnds.isEmpty, !readEnds.isEmpty]
        func drain(_ index: Int) {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while open[index] {
                let count = read(readEnds[index], &chunk, chunk.count)
                if count > 0 {
                    let data = Data(chunk.prefix(count))
                    if index == 0 {
                        stdout.append(data)
                        if let onOutput {
                            undelivered.append(data)
                            let complete = UTF8Prefix.completeLength(of: undelivered)
                            if complete > 0 {
                                onOutput(String(decoding: undelivered.prefix(complete), as: UTF8.self))
                                undelivered.removeFirst(complete)
                            }
                        }
                    } else {
                        stderr.append(data)
                    }
                } else if count == 0 {
                    open[index] = false
                } else if errno != EINTR {
                    return
                }
            }
        }

        let deadline = Date().addingTimeInterval(Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        var exitStatus: Int32 = 0
        var exited = false
        var timedOut = false
        while !exited {
            var pollers = readEnds.enumerated().map { index, descriptor in
                pollfd(fd: open[index] ? descriptor : -1, events: Int16(POLLIN), revents: 0)
            }
            _ = poll(&pollers, nfds_t(pollers.count), 100)
            drain(0)
            drain(1)
            let waited = waitpid(pid, &exitStatus, WNOHANG)
            if waited == pid { exited = true; break }
            if cancellation.isCancelled || Date() >= deadline {
                timedOut = !cancellation.isCancelled
                kill(-pid, SIGTERM)
                let grace = Date().addingTimeInterval(1)
                var info = siginfo_t()
                while Date() < grace {
                    info.si_pid = 0
                    if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid != 0 { break }
                    usleep(20_000)
                }
                // The leader is still unreaped here, so its pid can't be reused for another group yet.
                kill(-pid, SIGKILL)
                while waitpid(pid, &exitStatus, 0) == -1, errno == EINTR {}
                exited = true
            }
        }
        // Whatever the child wrote before exiting is already in the pipe.
        drain(0)
        drain(1)
        if let captureFile {
            stdout = (try? Data(contentsOf: URL(fileURLWithPath: captureFile.path))) ?? Data()
        }
        if cancellation.isCancelled { throw CancellationError() }
        let status: Int32 = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : -1
        return AndroidCLIResult(
            status: status,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

nonisolated enum UTF8Prefix {
    /// The length of `data` up to any multi-byte character its end cuts off.
    static func completeLength(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        guard !bytes.isEmpty else { return 0 }
        for back in 1...bytes.count {
            let byte = bytes[bytes.count - back]
            guard byte & 0xC0 == 0x80 else {
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return needed > back ? data.count - back : data.count
            }
        }
        return data.count
    }
}

nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
