import Foundation
import Testing
@testable import Plume

/// An agent is reaped only when this install spawned it and nothing but
/// launchd is left above its own process group. A live app, another install,
/// or a `claude` the user runs themselves is never touched.
struct OrphanedAgentSelectionTests {
    private let settings = "/Users/x/Library/Application Support/Plume/hooks/settings.json"
    private let ownGroup: pid_t = 500

    private func agent(_ pid: pid_t, parent: pid_t, group: pid_t? = nil, settings: String? = nil) -> ProcessTableEntry {
        ProcessTableEntry(
            pid: pid, parentPID: parent, groupID: group ?? pid,
            command: "claude -p --output-format stream-json --settings \(settings ?? self.settings)"
        )
    }

    private let launchd = ProcessTableEntry(pid: 1, parentPID: 0, groupID: 1, command: "/sbin/launchd")
    private let app = ProcessTableEntry(pid: 500, parentPID: 1, groupID: 500, command: "/Applications/Plume.app/Contents/MacOS/Plume")

    private func targets(_ table: [ProcessTableEntry], ledger: Set<pid_t> = []) -> [OrphanedAgentSelection.Target] {
        OrphanedAgentSelection.targets(in: table, settingsPath: settings, ledgerPIDs: ledger, ownGroupID: ownGroup)
    }

    @Test func reapsTheGroupOfAnAgentLaunchdAdopted() {
        #expect(targets([launchd, app, agent(700, parent: 1)]) == [.init(pid: 700, groupID: 700)])
    }

    @Test func leavesAnAgentWhoseAppIsAlive() {
        #expect(targets([launchd, app, agent(700, parent: 500)]).isEmpty)
    }

    @Test func leavesAnotherInstallsOrphan() {
        let debug = "/Users/x/Library/Application Support/Plume.debug/hooks/settings.json"
        #expect(targets([launchd, agent(700, parent: 1, settings: debug)]).isEmpty)
    }

    @Test func leavesAnUnmarkedClaude() {
        let user = ProcessTableEntry(pid: 700, parentPID: 1, groupID: 700, command: "claude -p --output-format stream-json")
        #expect(targets([launchd, user]).isEmpty)
    }

    @Test func reapsAnOrphanedShellAndItsAgentAsOneGroup() {
        let shell = ProcessTableEntry(pid: 700, parentPID: 1, groupID: 700, command: "/bin/sh -mc exec claude -p --settings \(settings)")
        #expect(targets([launchd, shell, agent(701, parent: 700, group: 700)]) == [.init(pid: 700, groupID: 700)])
    }

    @Test func signalsOnlyThePidWhenItSharesAnotherGroup() {
        let stranger = ProcessTableEntry(pid: 600, parentPID: 1, groupID: 600, command: "/usr/bin/whatever")
        #expect(targets([launchd, stranger, agent(700, parent: 1, group: 600)]) == [.init(pid: 700, groupID: nil)])
    }

    @Test func reapsALedgerProcessWithoutTheSettingsPath() {
        let codex = ProcessTableEntry(pid: 800, parentPID: 1, groupID: 800, command: "codex app-server")
        #expect(targets([launchd, codex], ledger: [800]) == [.init(pid: 800, groupID: 800)])
        #expect(targets([launchd, codex]).isEmpty)
    }

    @Test func leavesAnAgentWhoseParentIsGoneFromTheSnapshot() {
        #expect(targets([launchd, agent(700, parent: 650)]).isEmpty)
    }
}

struct ProcessTableTests {
    @Test func parsesPsColumnsKeepingSpacesInTheCommand() {
        let output = """
            1     0     1 /sbin/launchd
          346 51358   346 claude -p --settings /Users/x/Library/Application Support/Plume/hooks/settings.json
          bad line
        """
        #expect(ProcessTable.parse(output) == [
            ProcessTableEntry(pid: 1, parentPID: 0, groupID: 1, command: "/sbin/launchd"),
            ProcessTableEntry(
                pid: 346, parentPID: 51358, groupID: 346,
                command: "claude -p --settings /Users/x/Library/Application Support/Plume/hooks/settings.json"
            )
        ])
    }

    @Test func reportsAStartTimeOnlyForALiveProcess() {
        #expect(ProcessTable.startTime(of: getpid()) != nil)
        #expect(ProcessTable.startTime(of: 99_999_999) == nil)
    }
}

struct AgentProcessLedgerTests {
    private func makeLedger() -> AgentProcessLedger {
        AgentProcessLedger(file: FileManager.default.temporaryDirectory
            .appending(path: "ledger-\(UUID().uuidString)/agent-processes.json"))
    }

    @Test func recordsAndRemovesALiveProcess() {
        let ledger = makeLedger()
        ledger.record(getpid())
        #expect(ledger.liveEntries().map(\.pid) == [getpid()])
        ledger.remove(getpid())
        #expect(ledger.liveEntries().isEmpty)
    }

    @Test func dropsAnEntryWhosePidWasReused() throws {
        let ledger = makeLedger()
        let stale = [AgentProcessLedger.Entry(pid: getpid(), startTime: 1)]
        try FileManager.default.createDirectory(at: ledger.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stale).write(to: ledger.file)
        #expect(ledger.liveEntries().isEmpty)
    }
}

struct AgentProcessCloseOnExecTests {
    /// libghostty forks each terminal's shell without closing descriptors.
    /// `posix_spawn` with no file actions inherits the same way, so a child
    /// spawned like that must not keep the agent's stdin open: closing it has
    /// to reach the agent as EOF, well inside `terminate()`'s grace period
    /// before it escalates to `SIGTERM`.
    @Test(.timeLimit(.minutes(1))) func anInheritingChildDoesNotHoldTheAgentsStdinOpen() async throws {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let agent = AgentProcess(label: "cat", onLine: { continuation.yield($0) }, onExit: { _, _ in })
        try agent.start(arguments: ["/bin/cat"], workingDirectory: nil, environment: [:])
        agent.send(line: "ready")
        for await line in lines where line.contains("ready") { break }

        var inheritor: pid_t = 0
        let arguments = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&inheritor, "/bin/sleep", nil, nil, &argv, environ) == 0)
        defer {
            kill(inheritor, SIGKILL)
            waitpid(inheritor, nil, 0)
        }

        let started = ContinuousClock.now
        agent.terminate()
        await agent.waitUntilExited()
        #expect(ContinuousClock.now - started < .seconds(1.5))
    }

    @Test func marksBothEndsOfAPipe() {
        let pipe = Pipe.closeOnExec()
        for descriptor in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
    }
}
