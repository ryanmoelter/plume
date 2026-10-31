import Foundation
import Synchronization

nonisolated struct ChildProcessResult: Equatable, Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
}

nonisolated struct ChildProcessError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Spawns a command and captures its output. A run ends when the child exits, not when its pipes
/// close, because `android device remote connect` and a login shell can leave a process behind
/// that inherits them.
///
/// With `newProcessGroup`, the child leads its own process group, so a cancel or a timeout also
/// reaches what it started: `android` is a wrapper whose `android-cli` child would outlive a
/// signal to the wrapper alone. Only a cancel or a timeout signals the group, so a daemon a
/// finished command leaves behind survives. Without it, the child shares the caller's terminal
/// job, which a command that may open an editor needs.
///
/// A child killed by a signal reports 128 plus the signal number, as a shell does, and one that
/// can't be reaped reports -1.
nonisolated enum ChildProcess {
    enum Input: Sendable {
        case null
        case inherit
        case text(String)
    }

    enum Output: Sendable {
        case pipes
        case inherit
        /// Both streams go to one temporary file, so a daemon that inherits them has no pipe to
        /// break. Everything lands in `stdout`, and `onOutput` isn't called.
        case file
    }

    /// Blocks until the child exits or `timeout` passes. Throws only when the child can't be spawned.
    /// `environment` nil inherits this process's. `onOutput` gets each new piece of stdout as it arrives.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        input: Input = .null,
        output: Output = .pipes,
        newProcessGroup: Bool = true,
        timeout: Duration? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> ChildProcessResult {
        try run(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: workingDirectory, input: input, output: output,
            newProcessGroup: newProcessGroup, timeout: timeout, terminationGrace: .seconds(1),
            killsGroupOnExit: false, isCancelled: { false }, onOutput: onOutput
        )
    }

    /// Runs off the calling thread. Cancelling the task kills the child and throws `CancellationError`.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        input: Input = .null,
        output: Output = .pipes,
        newProcessGroup: Bool = true,
        timeout: Duration? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChildProcessResult {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let result = try run(
                            executable: executable, arguments: arguments, environment: environment,
                            workingDirectory: workingDirectory, input: input, output: output,
                            newProcessGroup: newProcessGroup, timeout: timeout, terminationGrace: .seconds(1),
                            killsGroupOnExit: false, isCancelled: { cancelled.withLock { $0 } }, onOutput: onOutput
                        )
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                        return result
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Stdout, or nil when the command can't be spawned or overruns `timeout`. Stderr is dropped.
    /// The whole process group is killed once the child exits, so nothing a login shell's profile
    /// backgrounds (`ssh-agent`, `(cmd &)`) outlives the read. A timeout kills at once, since an
    /// interactive zsh ignores SIGTERM.
    static func capturedOutput(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        guard let result = try? run(
            executable: executable, arguments: arguments, environment: nil, workingDirectory: nil,
            input: .null, output: .pipes, newProcessGroup: true, timeout: .seconds(timeout),
            terminationGrace: .zero, killsGroupOnExit: true, isCancelled: { false }, onOutput: nil
        ), !result.timedOut
        else { return nil }
        return result.stdout
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?,
        input: Input,
        output: Output,
        newProcessGroup: Bool,
        timeout: Duration?,
        terminationGrace: Duration,
        killsGroupOnExit: Bool,
        isCancelled: () -> Bool,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> ChildProcessResult {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Descriptors the parent closes once the child has its copies.
        var childEnds: [Int32] = []
        var closeAfterSpawn = true
        defer { if closeAfterSpawn { childEnds.forEach { close($0) } } }

        var inputWriteEnd: Int32?
        switch input {
        case .null:
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        case .inherit:
            inherit(STDIN_FILENO, into: &actions)
        case .text:
            let ends = try makePipe()
            childEnds.append(ends.read)
            inputWriteEnd = ends.write
            // A child that exits without reading would otherwise kill this process with SIGPIPE.
            _ = fcntl(ends.write, F_SETNOSIGPIPE, 1)
            posix_spawn_file_actions_adddup2(&actions, ends.read, STDIN_FILENO)
        }
        var inputWriteEndOwned = inputWriteEnd != nil
        defer { if inputWriteEndOwned, let inputWriteEnd { close(inputWriteEnd) } }

        var readEnds: [Int32] = []
        defer { readEnds.forEach { close($0) } }
        var captureFile: (path: String, descriptor: Int32)?
        defer {
            if let captureFile {
                // The daemon keeps the unlinked file open, so its space comes back only by truncating.
                _ = ftruncate(captureFile.descriptor, 0)
                close(captureFile.descriptor)
                unlink(captureFile.path)
            }
        }
        switch output {
        case .pipes:
            let out = try makePipe()
            readEnds.append(out.read)
            childEnds.append(out.write)
            let err = try makePipe()
            readEnds.append(err.read)
            childEnds.append(err.write)
            posix_spawn_file_actions_adddup2(&actions, out.write, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, err.write, STDERR_FILENO)
        case .inherit:
            inherit(STDOUT_FILENO, into: &actions)
            inherit(STDERR_FILENO, into: &actions)
        case .file:
            var template = Array((NSTemporaryDirectory() + "plume-child-XXXXXX").utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw ChildProcessError(message: "Couldn't create a temporary file.") }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            // Appending lets the truncate above rewind the daemon's writes too, since it shares this file offset.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_APPEND)
            captureFile = (template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, descriptor)
            posix_spawn_file_actions_adddup2(&actions, descriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, descriptor, STDERR_FILENO)
        }
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // An ignored disposition survives exec, so every signal is reset, or one this process
        // ignores would be ignored by the child as well.
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = environment.map { $0.map { strdup("\($0.key)=\($0.value)") } + [nil] }
        defer { envp?.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnStatus = if var envp {
            posix_spawn(&pid, executable, &actions, &attributes, argv, &envp)
        } else {
            posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        childEnds.forEach { close($0) }
        closeAfterSpawn = false
        guard spawnStatus == 0 else {
            throw ChildProcessError(message: "Couldn't run \(executable): \(String(cString: strerror(spawnStatus)))")
        }

        if case .text(let text) = input, let inputWriteEnd {
            inputWriteEndOwned = false
            // On its own thread, since a child that fills its output pipe before reading all its
            // input would otherwise deadlock against this one.
            Thread {
                let bytes = Array(text.utf8)
                var offset = 0
                while offset < bytes.count {
                    let written = bytes[offset...].withUnsafeBytes { write(inputWriteEnd, $0.baseAddress, $0.count) }
                    if written > 0 { offset += written } else if written < 0, errno == EINTR { continue } else { break }
                }
                close(inputWriteEnd)
            }.start()
        }

        for descriptor in readEnds { _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) }

        // Wakes the wait below the moment the child exits, rather than at its next timeout.
        let exitQueue = kqueue()
        defer { close(exitQueue) }
        var exitEvent = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: nil
        )
        // Registering fails for a child that already exited, which the first `waitpid` then finds.
        let pollTimeout: Int32 = kevent(exitQueue, &exitEvent, 1, nil, 0, nil) == 0 ? 100 : 10

        var stdout = Data()
        var stderr = Data()
        var undelivered = Data()
        var open = readEnds.map { _ in true }
        func drain(_ index: Int) {
            guard readEnds.indices.contains(index) else { return }
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

        let deadline = timeout.map { ContinuousClock.now + $0 }
        var exitStatus: Int32?
        var timedOut = false
        while true {
            var pollers = readEnds.enumerated().map { index, descriptor in
                pollfd(fd: open[index] ? descriptor : -1, events: Int16(POLLIN), revents: 0)
            }
            pollers.append(pollfd(fd: exitQueue, events: Int16(POLLIN), revents: 0))
            _ = poll(&pollers, nfds_t(pollers.count), pollTimeout)
            drain(0)
            drain(1)
            if hasExited(pid) {
                if killsGroupOnExit, newProcessGroup { kill(-pid, SIGKILL) }
                exitStatus = reap(pid)
                break
            }
            let cancelled = isCancelled()
            if cancelled || deadline.map({ ContinuousClock.now >= $0 }) == true {
                timedOut = !cancelled
                exitStatus = terminate(pid, group: newProcessGroup, grace: terminationGrace)
                break
            }
        }
        // Whatever the child wrote before exiting is already in the pipe.
        drain(0)
        drain(1)
        if let captureFile {
            stdout = (try? Data(contentsOf: URL(fileURLWithPath: captureFile.path))) ?? Data()
        }
        return ChildProcessResult(
            status: exitStatus.map(shellStatus) ?? -1,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// SIGTERM and `grace` to exit, then SIGKILL; a zero grace skips the SIGTERM. Reaps the child.
    private static func terminate(_ pid: pid_t, group: Bool, grace: Duration) -> Int32? {
        let target = group ? -pid : pid
        if grace > .zero {
            kill(target, SIGTERM)
            let end = ContinuousClock.now + grace
            while ContinuousClock.now < end, !hasExited(pid) { usleep(20_000) }
        }
        // The leader is still unreaped here, so its pid can't be reused for another group yet.
        kill(target, SIGKILL)
        return reap(pid)
    }

    /// Leaves the child unreaped, so its pid, and with it the process group's id, can't be reused
    /// before the group is signalled. A failed wait counts as exited: with ECHILD there's nothing
    /// left to wait for, and the kevent that wakes the loop has already fired.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid }
            if errno != EINTR { return true }
        }
    }

    /// The raw wait status, or nil when the child can't be reaped.
    private static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            if waitpid(pid, &status, 0) == pid { return status }
            if errno != EINTR { return nil }
        }
    }

    private static func shellStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ChildProcessError(message: "Couldn't create a pipe.") }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        return (descriptors[0], descriptors[1])
    }

    /// `CLOEXEC_DEFAULT` closes every descriptor not named, the standard ones included. A closed
    /// one is left closed, since naming it fails the spawn.
    private static func inherit(_ descriptor: Int32, into actions: inout posix_spawn_file_actions_t?) {
        guard fcntl(descriptor, F_GETFD) != -1 else { return }
        posix_spawn_file_actions_addinherit_np(&actions, descriptor)
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
