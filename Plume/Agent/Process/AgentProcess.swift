import Foundation
import os

/// Owns one agent subprocess and frames NDJSON in both directions.
///
/// Deliberately knows nothing about chat, status, permissions, or which CLI it
/// is running: it delivers whole lines and writes lines back. The session that
/// owns it supplies meaning.
final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let queue = DispatchQueue(label: "com.ryanmoelter.Plume.agent-process")

    /// Partial trailing line carried between reads: a pipe read can split a
    /// JSON line anywhere, and a half line decodes to nothing.
    private var buffer = Data()
    private var isRunning = false

    /// Last stderr line, kept so a nonzero exit can say why it failed. A
    /// launch that dies before any output arrives (the CLI not on PATH, say)
    /// has nothing else to report.
    private var lastErrorLine: String?

    /// Whether any output arrived. Separates a launch that never started from
    /// a session that ran and later exited.
    private var didReceiveLine = false

    /// Names the CLI in log lines.
    private let label: String
    private let onLine: @Sendable (String) -> Void
    private let onExit: @Sendable (Int32, String?) -> Void

    init(
        label: String,
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32, String?) -> Void
    ) {
        self.label = label
        self.onLine = onLine
        self.onExit = onExit
    }

    func start(arguments: [String], workingDirectory: String?, environment: [String: String]) throws {
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
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env

        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Log.agent.error("\(self?.label ?? "agent", privacy: .public) stderr: \(text, privacy: .public)")
            self?.queue.async { self?.lastErrorLine = text }
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }

        try process.run()
        queue.sync { isRunning = true }
    }

    /// The spawned pid, or nil before launch. Distinguishes an agent this app
    /// owns from one orphaned by a previous run.
    var processIdentifier: pid_t? {
        queue.sync { isRunning ? process.processIdentifier : nil }
    }

    /// Writes one NDJSON line, reporting `false` when the process is already
    /// gone. A caller sending the user's own text must surface that rather
    /// than let the message disappear.
    @discardableResult
    func send(line: String) -> Bool {
        queue.sync {
            guard isRunning, let data = (line + "\n").data(using: .utf8) else { return false }
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
    func terminate() {
        let wasRunning = queue.sync {
            guard isRunning else { return false }
            isRunning = false
            return true
        }
        guard wasRunning else { return }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()

        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard waitForExit(within: Self.gracePeriod) == false else { return }

        signalGroup(SIGTERM, pid: pid)
        guard waitForExit(within: Self.gracePeriod) == false else { return }

        signalGroup(SIGKILL, pid: pid)
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
            guard let self else { return }
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

    private func finish(status: Int32) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            // A run that never produced a line failed to launch, so its
            // stderr explains why. Once the stream has started, stderr is
            // just the login shell's own chatter and explains nothing.
            self.onExit(status, self.didReceiveLine ? nil : self.lastErrorLine)
        }
    }
}
