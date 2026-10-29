import Foundation
import Testing

@testable import Plume

/// `android device remote connect` exits leaving a daemon that may hold its pipes open, so a run
/// ends when the child exits, not when its pipes close.
struct ChildProcessTests {
    private func sh(_ script: String, timeout: Duration = .seconds(10), capturesToFile: Bool = false) async throws -> AndroidCLIResult {
        try await ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", script], environment: ProcessInfo.processInfo.environment,
            timeout: timeout, capturesToFile: capturesToFile, onOutput: nil
        )
    }

    @Test func capturesBothStreamsAndTheExitStatus() async throws {
        let result = try await sh("echo out; echo err >&2; exit 3")
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.status == 3)
        #expect(!result.succeeded)
    }

    @Test func returnsWhenTheChildExitsThoughABackgroundProcessHoldsThePipe() async throws {
        let start = ContinuousClock.now
        let result = try await sh("sleep 5 & echo started")
        #expect(result.stdout == "started\n")
        #expect(result.succeeded)
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func aGrandchildKeepsWritingAfterAFileCapturedParentExits() async throws {
        let marker = NSTemporaryDirectory() + "plume-grandchild-\(UUID().uuidString)"
        defer { unlink(marker) }
        let script = "(while :; do echo tick; sleep 0.05; done) & echo $! > \(marker); echo port 59095"
        let result = try await sh(script, capturesToFile: true)
        #expect(result.stdout.contains("port 59095"))
        #expect(result.succeeded)

        let text = try String(contentsOfFile: marker, encoding: .utf8)
        let grandchild = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(grandchild, SIGKILL) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(grandchild, 0) == 0)
    }

    @Test func killsAChildThatOverrunsItsTimeout() async throws {
        let result = try await sh("echo partial; exec sleep 30", timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.stdout == "partial\n")
    }

    @Test func cancellingKillsTheChildsChildrenToo() async throws {
        let grandchild = LockedValue<pid_t?>(nil)
        let run = Task {
            try await ChildProcess.run(
                executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"],
                environment: ProcessInfo.processInfo.environment, timeout: .seconds(20)
            ) { text in
                if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { grandchild.value = pid }
            }
        }
        for _ in 0..<500 where grandchild.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(grandchild.value)
        #expect(kill(pid, 0) == 0)

        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        // Orphaned, the grandchild is reaped by launchd once it dies.
        for _ in 0..<300 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1)
    }

    @Test func deliversEachNewPieceOfOutputOnce() async throws {
        let pieces = LockedValue<[String]>([])
        let result = try await ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", "printf one; sleep 0.3; printf two"],
            environment: ProcessInfo.processInfo.environment, timeout: .seconds(10)
        ) { text in pieces.value.append(text) }
        #expect(pieces.value.joined() == "onetwo")
        #expect(pieces.value.count == 2)
        #expect(result.stdout == "onetwo")
    }

    @Test func holdsBackACharacterCutOffMidSequence() {
        let euro = Data("€".utf8)
        #expect(UTF8Prefix.completeLength(of: Data("ab".utf8) + euro.prefix(2)) == 2)
        #expect(UTF8Prefix.completeLength(of: Data("ab".utf8) + euro) == 5)
        #expect(UTF8Prefix.completeLength(of: Data()) == 0)
    }

    @Test func lineBufferReturnsOnlyCompletedLines() {
        let buffer = LineBuffer()
        #expect(buffer.completeLines(appending: "New reservation created with id 3f3j").isEmpty)
        #expect(buffer.completeLines(appending: "pxdv5lw6y. Ends\nWaiting") == ["New reservation created with id 3f3jpxdv5lw6y. Ends"])
        #expect(buffer.completeLines(appending: "...\n") == ["Waiting..."])
    }
}
