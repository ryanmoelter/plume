import Foundation
import Synchronization
import Testing

@testable import Plume

/// A child can be reaped before its last line is read. `onExit` still has to
/// come after every line, so a caller that tears down from `onExit` loses
/// nothing. A writer that outlives the child makes that ordering
/// deterministic: its line lands well after the exit.
struct AgentProcessOutputTests {
    @Test(.timeLimit(.minutes(1))) func theLastLineArrivesBeforeOnExitThoughOnExitTerminates() async throws {
        let script = "echo first; (sleep 0.2; echo final) & exit 0"
        for _ in 0..<2 {
            let lines = Mutex<[String]>([])
            let linesAtExit = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                let box = Mutex<AgentProcess?>(nil)
                let process = AgentProcess(
                    label: "output drain test",
                    onLine: { line in lines.withLock { $0.append(line) } },
                    onExit: { _, _ in
                        let seen = lines.withLock { $0 }
                        let process = box.withLock { box in
                            defer { box = nil }
                            return box
                        }
                        DispatchQueue.global().async {
                            process?.terminate()
                            continuation.resume(returning: seen)
                        }
                    }
                )
                box.withLock { $0 = process }
                do {
                    try process.start(arguments: ["/bin/sh", "-c", script], workingDirectory: nil, environment: [:])
                } catch {
                    continuation.resume(returning: [])
                }
            }
            #expect(linesAtExit.last == "final")
        }
    }

    @Test(.timeLimit(.minutes(1))) func noLineArrivesAfterOnExitWhenAGrandchildHoldsStdout() async throws {
        let lines = Mutex<[String]>([])
        let linesAtExit = Mutex<[String]?>(nil)
        let holder = Mutex<AgentProcess?>(nil)
        let exited = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = AgentProcess(
                label: "late grandchild test",
                onLine: { line in lines.withLock { $0.append(line) } },
                onExit: { _, _ in
                    linesAtExit.withLock { $0 = lines.withLock { $0 } }
                    continuation.resume(returning: true)
                }
            )
            holder.withLock { $0 = process }
            do {
                try process.start(
                    arguments: ["/bin/sh", "-c", "echo first; (sleep 2; echo late) & exit 0"],
                    workingDirectory: nil, environment: [:])
            } catch {
                continuation.resume(returning: false)
            }
        }
        #expect(exited)
        defer { holder.withLock { $0 = nil } }
        try await Task.sleep(for: .seconds(3))
        #expect(linesAtExit.withLock { $0 } == ["first"])
        #expect(lines.withLock { $0 } == ["first"])
    }

    /// The child exits 3 while a grandchild keeps stdout open, so the exit is
    /// still held when the caller terminates.
    @Test(.timeLimit(.minutes(1))) func anExitTheChildReachedSurvivesATerminateDuringTheDrain() async throws {
        let exits = Mutex<[Int32]>([])
        let firstLine = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let process = AgentProcess(
            label: "terminate during drain test",
            onLine: { _ in firstLine.withLock { $0?.resume(); $0 = nil } },
            onExit: { status, _ in exits.withLock { $0.append(status) } }
        )
        await withCheckedContinuation { continuation in
            firstLine.withLock { $0 = continuation }
            do {
                try process.start(
                    arguments: ["/bin/sh", "-c", "echo first; (sleep 4; echo late) & exit 3"],
                    workingDirectory: nil, environment: [:])
            } catch {
                firstLine.withLock { $0?.resume(); $0 = nil }
            }
        }
        await process.waitUntilExited()
        #expect(process.processIdentifier == nil)
        process.terminate()
        for _ in 0..<60 where exits.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        process.terminate()
        #expect(exits.withLock { $0 } == [3])
    }

    /// Stdout closes at once while a grandchild writes stderr after the exit,
    /// the order a `command not found` launch can arrive in.
    @Test(.timeLimit(.minutes(1))) func aFailedLaunchReportsStderrThatArrivesAfterTheExit() async throws {
        let holder = Mutex<AgentProcess?>(nil)
        let exit = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String?), Never>) in
            let process = AgentProcess(
                label: "late stderr test",
                onLine: { _ in },
                onExit: { status, reason in continuation.resume(returning: (status, reason)) }
            )
            holder.withLock { $0 = process }
            do {
                try process.start(
                    arguments: ["/bin/sh", "-c", "(exec 1>&-; sleep 0.3; echo 'claude: command not found' >&2) & exit 127"],
                    workingDirectory: nil, environment: [:])
            } catch {
                continuation.resume(returning: (-1, nil))
            }
        }
        defer { holder.withLock { $0 = nil } }
        #expect(exit.0 == 127)
        #expect(exit.1 == "claude: command not found")
    }
}
