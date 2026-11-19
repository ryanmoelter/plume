import Foundation
import os

/// Owns one agent subprocess and frames NDJSON in both directions.
///
/// Deliberately knows nothing about chat, status, permissions, or which CLI it
/// is running: it delivers whole lines and writes lines back. The session that
/// owns it supplies meaning.
nonisolated final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe.closeOnExec()
    private let outPipe = Pipe.closeOnExec()
    private let errPipe = Pipe.closeOnExec()
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.agent-process")

    /// Partial trailing line carried between reads: a pipe read can split a
    /// JSON line anywhere, and a half line decodes to nothing.
    private var buffer = Data()
    /// False once the caller ends the process or its exit is delivered.
    private var isRunning = false

    /// Last stderr line, kept so a nonzero exit can say why it failed. A
    /// launch that dies before any output arrives (the CLI not on PATH, say)
    /// has nothing else to report.
    private var lastErrorLine: String?

    /// The CLI's own last `Error:` line, prefix dropped. Unlike `lastErrorLine`
    /// it survives the hook output a CLI prints as it exits, and it explains a
    /// failure even after the stream has started.
    private var lastReportedError: String?

    /// Whether any output arrived. Separates a launch that never started from
    /// a session that ran and later exited.
    private var didReceiveLine = false

    /// Set once the child has exited, which can be well after `terminate()`
    /// returned.
    private var hasProcessExited = false
    private var didLaunch = false
    private var hasOutputEnded = false
    /// Held until stdout reaches end of file, so `onExit` follows every line.
    private var pendingExitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// Names the CLI in log lines.
    private let label: String
    private let onLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32, String?) -> Void
    private let ledger: AgentProcessLedger?
    private var launchedPID: pid_t?

    init(
        label: String,
        ledger: AgentProcessLedger? = nil,
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32, String?) -> Void
    ) {
        self.label = label
        self.ledger = ledger
        self.onLine = onLine
        self.onExit = onExit
    }

    func start(
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        removingEnvironment: [String] = []
    ) throws {
        // The agent reaches PATH only through the user's shell profile, which a
        // GUI-launched app does not inherit, so the command runs inside a
        // login shell exactly as terminal tabs do.
        //
        // `-m` (job control) puts the child in its own process group, so
        // `kill(-pid)` reaps the whole tree rather than one process — see
        // `terminate()`. Each shell is handed a single trailing command and
        // execs it away, so the pid is the agent itself.

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-mc", LoginShellCommand.wrap(arguments: arguments)]

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.environment = LoginShellCommand.childEnvironment(overrides: environment, removing: removingEnvironment)

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // A handle at end of file stays readable, so a handler left in place
        // there is called again and again.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.outputEnded()
                return
            }
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let self else { return }
            Log.agent.error("\(self.label, privacy: .public) stderr: \(text, privacy: .public)")
            let reported = Self.reportedError(in: text)
            queue.async {
                self.lastErrorLine = text
                if let reported { self.lastReportedError = reported }
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.recordExit()
            self?.finish(status: process.terminationStatus)
        }

        try process.run()
        let pid = process.processIdentifier
        queue.sync {
            isRunning = true
            didLaunch = true
            launchedPID = pid
        }
        queue.async { [ledger] in ledger?.record(pid) }
    }

    /// Returns once the child has exited, which `terminate()` bounds by
    /// escalating to `SIGKILL`. At once for a process that never launched.
    func waitUntilExited() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !didLaunch || hasProcessExited {
                    continuation.resume()
                } else {
                    exitWaiters.append(continuation)
                }
            }
        }
    }

    private func recordExit() {
        queue.async { [self] in
            hasProcessExited = true
            if let launchedPID { ledger?.remove(launchedPID) }
            let waiters = exitWaiters
            exitWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    /// The spawned pid, or nil before launch. Distinguishes an agent this app
    /// owns from one orphaned by a previous run.
    var processIdentifier: pid_t? {
        queue.sync { isRunning && !hasProcessExited ? process.processIdentifier : nil }
    }

    /// Writes one NDJSON line, reporting `false` when the process is already
    /// gone. A caller sending the user's own text must surface that rather
    /// than let the message disappear.
    @discardableResult
    func send(line: String) -> Bool {
        queue.sync {
            guard isRunning, !hasProcessExited, let data = (line + "\n").data(using: .utf8) else { return false }
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: data)
                return true
            } catch {
                Log.agent.error("Agent write failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Ends the process. Prefer an `interrupt` control request to stop a turn;
    /// this tears the whole session down.
    ///
    /// Escalates rather than trusting any one step. Closing stdin is the
    /// documented way to ask `claude` to exit, but an app that is quitting
    /// cannot wait indefinitely for it to notice, and a child that outlives
    /// the app keeps writing the transcript a later run will resume from.
    /// `SIGTERM` then `SIGKILL` go to the process *group*, so the agent's own
    /// children go with it rather than outliving their parent.
    ///
    /// Returns at once: the escalation waits seconds for the child, so it runs
    /// on a background queue. A quitting app calls `awaitTerminations` so the
    /// escalation still finishes before the process exits.
    ///
    /// A child that already exited on its own still reports through `onExit`,
    /// after its remaining lines: only a process this call ends is silent.
    func terminate() {
        let state: (wasRunning: Bool, hadExited: Bool) = queue.sync {
            guard isRunning else { return (false, false) }
            if hasProcessExited { return (true, true) }
            isRunning = false
            return (true, false)
        }
        try? inPipe.fileHandleForWriting.close()
        guard !state.hadExited else { return }
        // Whoever ends the process wants no more of its output.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard state.wasRunning else { return }

        guard process.isRunning else { return }
        let pid = process.processIdentifier
        Self.terminations.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { Self.terminations.leave() }
            guard waitForExit(within: Self.gracePeriod) == false else { return }

            signalGroup(SIGTERM, pid: pid)
            guard waitForExit(within: Self.gracePeriod) == false else { return }

            signalGroup(SIGKILL, pid: pid)
        }
    }

    private var hasDeliveredExit = false

    private static let terminations = DispatchGroup()

    /// Blocks until every `terminate()` in flight has seen its child exit or
    /// escalated to `SIGKILL`. Only for app termination.
    static func awaitTerminations() {
        _ = terminations.wait(timeout: .now() + gracePeriod * 2 + 1)
    }

    /// Long enough for `claude` to notice stdin closed and flush its
    /// transcript, short enough not to stall app termination.
    private static let gracePeriod: TimeInterval = 2

    /// Signals the child's whole process group, falling back to the single
    /// process when it leads no group of its own. `-m` on the spawning shell
    /// is what creates that group.
    private func signalGroup(_ signal: Int32, pid: pid_t) {
        if kill(-pid, signal) == -1 && errno == ESRCH {
            kill(pid, signal)
        }
    }

    private func waitForExit(within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private func consume(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.hasDeliveredExit else { return }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                self.didReceiveLine = true
                self.onLine(line)

            }
        }
    }

    /// How long an exit waits for stdout to close. A grandchild that keeps
    /// the pipe open would otherwise hold `onExit` back for its whole life.
    private static let outputDrainGrace: TimeInterval = 1

    /// The child can exit before the last of its output is read, so the exit
    /// waits for stdout to end and every line reaches `onLine` first.
    private func finish(status: Int32) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingExitStatus = status
            if self.hasOutputEnded {
                self.deliverExit()
            } else {
                self.queue.asyncAfter(deadline: .now() + Self.outputDrainGrace) { self.deliverExit() }
            }
        }
    }

    /// Enqueued after the handler's last `consume`, so it runs after it.
    private func outputEnded() {
        queue.async { [weak self] in
            guard let self else { return }
            self.hasOutputEnded = true
            self.deliverExit()
        }
    }

    private func deliverExit() {
        guard let status = pendingExitStatus else { return }
        pendingExitStatus = nil
        guard isRunning else { return }
        isRunning = false
        hasDeliveredExit = true
        outPipe.fileHandleForReading.readabilityHandler = nil
        // A run that never produced a line failed to launch, so its stderr
        // explains why. Once the stream has started, only the CLI's own
        // `Error:` line does; the rest is login-shell chatter.
        onExit(status, lastReportedError ?? (didReceiveLine ? nil : lastErrorLine))
    }

    nonisolated static func reportedError(in stderr: String) -> String? {
        let prefix = "Error:"
        guard let line = stderr.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let message = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? nil : message
    }
}
