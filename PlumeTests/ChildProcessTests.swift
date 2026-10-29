import Foundation
import Testing

@testable import Plume

/// `android device remote connect` exits leaving a daemon that may hold its pipes open, so a run
/// ends when the child exits, not when its pipes close.
struct ChildProcessTests {
    private func sh(_ script: String, timeout: Duration = .seconds(10)) async throws -> AndroidCLIResult {
        try await ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", script], environment: ProcessInfo.processInfo.environment,
            timeout: timeout, onOutput: nil
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

    @Test func killsAChildThatOverrunsItsTimeout() async throws {
        let result = try await sh("echo partial; exec sleep 30", timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.stdout == "partial\n")
    }
}
