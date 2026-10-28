import Darwin
import Foundation

struct EmulatorLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A spawned emulator. It outlives Plume, so this is a handle to read from, never to terminate.
nonisolated final class EmulatorLaunch: @unchecked Sendable {
    let pid: Int32
    let logURL: URL
    let launchedAt: Date
    private let lock = NSLock()
    private var exited = false

    init(pid: Int32, logURL: URL, launchedAt: Date) {
        self.pid = pid
        self.logURL = logURL
        self.launchedAt = launchedAt
    }

    var hasExited: Bool { lock.withLock { exited } }

    /// Reaps the child once. The lock keeps the exit handler and the post-spawn check from both calling `waitpid`.
    fileprivate func reap(blocking: Bool) -> Bool {
        lock.withLock {
            if exited { return true }
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) {
                    exited = true
                    return true
                }
                if result == -1 && errno == EINTR { continue }
                return false
            }
        }
    }

    func logTail(lines: Int = 20) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}

@MainActor enum EmulatorLauncher {
    static func logURL(avdID: String) -> URL {
        AppPaths.applicationSupport.appending(path: "Emulators/\(avdID).log")
    }

    static func arguments(avdID: String) -> [String] {
        ["-avd", avdID, "-no-window", "-grpc-use-token", "-no-boot-anim"]
    }

    /// Spawns in its own session so closing a tab or quitting Plume leaves the emulator running.
    static func boot(avdID: String, sdk: AndroidSDK) throws -> EmulatorLaunch {
        guard let emulatorURL = sdk.emulatorURL else {
            throw EmulatorLaunchError(message: "The Android emulator isn't installed in \(sdk.root.path).")
        }
        let logURL = logURL(avdID: avdID)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard logFD >= 0 else { throw EmulatorLaunchError(message: "Could not open \(logURL.path): \(String(cString: strerror(errno)))") }
        defer { close(logFD) }
        let nullFD = open("/dev/null", O_RDONLY)
        guard nullFD >= 0 else { throw EmulatorLaunchError(message: "Could not open /dev/null") }
        defer { close(nullFD) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT keeps Plume's pipes and PTY masters out of the emulator; the dup2'd 0/1/2 survive.
        // The signal mask and dispositions are reset because ignored signals survive exec.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [emulatorURL.path] + arguments(avdID: avdID)
        let environment = ProcessInfo.processInfo.environment
            .merging(sdk.launchEnvironment) { _, new in new }
            .map { "\($0.key)=\($0.value)" }

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        let launchedAt = Date()
        var pid: pid_t = 0
        let status = posix_spawn(&pid, emulatorURL.path, &actions, &attributes, cArgv, cEnv)
        guard status == 0 else {
            throw EmulatorLaunchError(message: "Could not start the emulator: \(String(cString: strerror(status)))")
        }

        let launch = EmulatorLaunch(pid: pid, logURL: logURL, launchedAt: launchedAt)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            _ = launch.reap(blocking: true)
            EmulatorLog.info("emulator launcher pid \(pid) for \(avdID) exited")
            source.cancel()
        }
        source.resume()
        // An exit before `resume()` may never be delivered to the source.
        if launch.reap(blocking: false) { source.cancel() }
        return launch
    }
}
