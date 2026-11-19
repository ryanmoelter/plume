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
}
