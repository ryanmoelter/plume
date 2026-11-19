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
}
