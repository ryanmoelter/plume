import Darwin
import Foundation
import Synchronization

/// What a command-mode command did: what it printed on each stream, and how
/// it ended.
nonisolated struct CommandModeResult: Equatable, Sendable {
    enum Ending: Equatable, Sendable {
        case exited
        /// Killed at `CommandModeRunner.timeout`. Output up to that point is
        /// kept, and `stderr` says why it stopped.
        case timedOut
        /// Killed by the user. Nothing is sent to the agent.
        case cancelled
    }

    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    var ending: Ending = .exited

    /// The user turn sent to the agent, tagged as the CLI's own bash mode
    /// writes it rather than as prose.
    ///
    /// Claude Code records the command and its output as two transcript
    /// lines, but both carry one `promptId` and the reply comes only after
    /// the second — so they are one prompt, and go as one message here.
    /// Sending them as two would start a turn on the command alone and let
    /// the agent answer before its output existed.
    ///
    /// Matching the tags is what makes the agent read this the way it reads
    /// its own bash mode, and `InjectedContent` classifies the same tags, so
    /// the chat renders it as a shell marker rather than words the user
    /// typed. Both output tags are always written, empty or not, as the CLI
    /// does. The exit code has no tag of its own and is left out: a failing
    /// command explains itself through stderr.
    var transcriptText: String {
        """
        <bash-input>\(command)</bash-input>
        <bash-stdout>\(stdout)</bash-stdout><bash-stderr>\(stderr)</bash-stderr>
        """
    }
}

/// Runs a command-mode command and captures what it printed.
///
/// Separate from `GitRunner`, which throws on a nonzero exit and blocks its
/// thread. Neither suits an arbitrary user command: a failure is a normal
/// outcome whose exit code the agent should see, and the wait happens on the
/// send path.
///
/// Spawned with `posix_spawn` rather than `Process` so the command gets its
/// own process group: the login shell forks the real command, and a timeout
/// or cancel has to kill everything it started, not just the shell.
nonisolated enum CommandModeRunner {
    /// Output past this is elided. A single `!find /` would otherwise spend
    /// the conversation's whole context on one command.
    static let maximumOutputLines = 100
    static let maximumOutputBytes = 20_000
    static let timeout: Duration = .seconds(120)

    /// Cancelling the calling task kills the command and returns a
    /// `.cancelled` result.
    static func run(
        _ command: String,
        in directory: String?,
        timeout: Duration = timeout
    ) async -> CommandModeResult {
        let handle = ProcessGroupHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: runSynchronously(command, in: directory, timeout: timeout, handle: handle)
                    )
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runSynchronously(
        _ command: String,
        in directory: String?,
        timeout: Duration,
        handle: ProcessGroupHandle
    ) -> CommandModeResult {
        let stdout = OutputBuffer()
        let stderr = OutputBuffer()
        let pid: pid_t
        do {
            pid = try spawn(command, in: directory, stdout: stdout, stderr: stderr)
        } catch {
            return CommandModeResult(command: command, stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
        handle.started(pid)

        let exitStatus = Mutex<Int32>(-1)
        let finished = DispatchGroup()
        stdout.drain(in: finished)
        stderr.drain(in: finished)
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            exitStatus.withLock { $0 = waitForExit(pid) }
            finished.leave()
        }

        var ending = CommandModeResult.Ending.exited
        if finished.wait(timeout: .now() + timeout.timeInterval) == .timedOut {
            handle.terminate()
            ending = .timedOut
        }
        // Bounded: a descendant that left the process group can hold a pipe
        // open past every kill. Its output stops here rather than the run.
        _ = finished.wait(timeout: .now() + ProcessGroupHandle.killGrace + 1)
        handle.finished()
        if handle.isCancelled { ending = .cancelled }

        var errorText = truncated(stderr.text)
        if ending == .timedOut {
            if !errorText.isEmpty { errorText += "\n" }
            errorText += "Timed out after \(Int(timeout.timeInterval)) seconds"
        }
        return CommandModeResult(
            command: command,
            stdout: truncated(stdout.text),
            stderr: errorText,
            exitCode: exitStatus.withLock { $0 },
            ending: ending
        )
    }

    // MARK: Spawning

    private struct SpawnError: LocalizedError {
        let call: String
        let code: Int32
        var errorDescription: String? { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    private static func spawn(
        _ command: String,
        in directory: String?,
        stdout: OutputBuffer,
        stderr: OutputBuffer
    ) throws -> pid_t {
        let outputPipe = try makePipe()
        let errorPipe = try makePipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // Nothing can type into it, so a command that reads stdin gets EOF
        // rather than waiting for the timeout.
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outputPipe.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errorPipe.write, STDERR_FILENO)
        if let directory {
            posix_spawn_file_actions_addchdir(&fileActions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // `CLOEXEC_DEFAULT` keeps every descriptor Plume holds out of the
        // child; only the three set up above survive. An ignored disposition
        // survives exec, so every signal is reset too — otherwise one the app
        // ignores (SIGTERM, SIGPIPE) is ignored by the command as well.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        // A GUI-launched app inherits no shell PATH, so the command runs in a
        // login shell. Non-interactive, unlike a terminal tab's: `.zshrc`
        // warnings would otherwise be captured as part of every result.
        let arguments = ["/bin/sh", "-c", LoginShellCommand.wrapNonInteractive(command)]
        let environment = ProcessInfo.processInfo.environment
            .merging(LoginShellCommand.plumeEnvironment) { _, override in override }
            .map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argv, envp)
            }
        }
        close(outputPipe.write)
        close(errorPipe.write)
        guard result == 0 else {
            close(outputPipe.read)
            close(errorPipe.read)
            throw SpawnError(call: "posix_spawn", code: result)
        }
        stdout.descriptor = outputPipe.read
        stderr.descriptor = errorPipe.read
        return pid
    }

    /// Both ends close on exec, so a process spawned elsewhere in Plume at
    /// the same moment cannot inherit a write end and hold the pipe open.
    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw SpawnError(call: "pipe", code: errno) }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (descriptors[0], descriptors[1])
    }

    private static func withCStrings<Result>(
        _ strings: [String],
        _ body: ([UnsafeMutablePointer<CChar>?]) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }

    /// The exit code, or 128 plus the signal for a killed command — the
    /// shell's own convention.
    private static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    // MARK: Output

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Caps output by lines and by bytes, since either alone lets the other
    /// through — a thousand short lines, or one enormous one.
    static func truncated(_ output: String) -> String {
        var result = output
        var didElide = false

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maximumOutputLines {
            result = lines.prefix(maximumOutputLines).joined(separator: "\n")
            didElide = true
        }
        if result.utf8.count > maximumOutputBytes {
            result = String(decoding: Array(result.utf8.prefix(maximumOutputBytes)), as: UTF8.self)
            didElide = true
        }
        return didElide ? result + "\n…output truncated" : result
    }

    /// One stream's output, read on its own thread so neither pipe can fill
    /// and stall the child while the other is being read.
    nonisolated private final class OutputBuffer: @unchecked Sendable {
        /// Well past what `truncated` keeps, so the elision still shows, but
        /// bounded so a runaway command cannot grow it without limit.
        private static let retainedBytes = CommandModeRunner.maximumOutputBytes * 4

        var descriptor: Int32 = -1
        private let data = Mutex(Data())

        var text: String { CommandModeRunner.text(data.withLock { $0 }) }

        func drain(in group: DispatchGroup) {
            group.enter()
            let descriptor = descriptor
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var chunk = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = read(descriptor, &chunk, chunk.count)
                    if count > 0 {
                        data.withLock { data in
                            guard data.count < Self.retainedBytes else { return }
                            data.append(contentsOf: chunk.prefix(count))
                        }
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                close(descriptor)
                group.leave()
            }
        }
    }
}

/// The spawned command's process group, shared between the thread running it
/// and the task-cancellation handler.
nonisolated private final class ProcessGroupHandle: Sendable {
    static let killGrace: TimeInterval = 2

    private struct State {
        var pid: pid_t?
        var isCancelled = false
        var isFinished = false
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    /// Kills at once if cancellation beat the spawn.
    func started(_ pid: pid_t) {
        let cancelledEarly = state.withLock { state in
            state.pid = pid
            return state.isCancelled
        }
        if cancelledEarly { terminate() }
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
        terminate()
    }

    /// Stops signalling: once the run is over its process group id is free
    /// to be reused by something else.
    func finished() {
        state.withLock { $0.isFinished = true }
    }

    /// SIGTERM to the whole group, then SIGKILL for whatever ignored it.
    func terminate() {
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            signal(SIGKILL)
        }
    }

    private func signal(_ signal: Int32) {
        state.withLock { state in
            guard let pid = state.pid, !state.isFinished else { return }
            kill(-pid, signal)
        }
    }
}

private extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
