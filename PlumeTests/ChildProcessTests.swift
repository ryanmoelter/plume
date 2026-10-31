import Foundation
import Synchronization
import Testing

@testable import Plume

/// `android device remote connect` exits leaving a daemon that may hold its pipes open, so a run
/// ends when the child exits, not when its pipes close.
struct ChildProcessTests {
    private func sh(_ script: String, timeout: Duration = .seconds(10), output: ChildProcess.Output = .pipes) async throws -> ChildProcessResult {
        try await ChildProcess.run(executable: "/bin/sh", arguments: ["-c", script], output: output, timeout: timeout)
    }

    @Test func capturesBothStreamsAndTheExitStatus() async throws {
        let result = try await sh("echo out; echo err >&2; exit 3")
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.status == 3)
        #expect(!result.timedOut)
    }

    @Test func returnsWhenTheChildExitsThoughABackgroundProcessHoldsThePipe() async throws {
        let start = ContinuousClock.now
        let result = try await sh("sleep 5 & echo started")
        #expect(result.stdout == "started\n")
        #expect(result.status == 0)
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func aGrandchildKeepsWritingAfterAFileCapturedParentExits() async throws {
        let marker = NSTemporaryDirectory() + "plume-grandchild-\(UUID().uuidString)"
        defer { unlink(marker) }
        let script = "(while :; do echo tick; sleep 0.05; done) & echo $! > \(marker); echo port 59095"
        let result = try await sh(script, output: .file)
        #expect(result.stdout.contains("port 59095"))
        #expect(result.status == 0)

        let text = try String(contentsOfFile: marker, encoding: .utf8)
        let grandchild = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(grandchild, SIGKILL) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(grandchild, 0) == 0)
    }

    @Test func aFileCapturedRunTruncatesTheFileItsGrandchildKeeps() async throws {
        let marker = NSTemporaryDirectory() + "plume-capture-size-\(UUID().uuidString)"
        defer { unlink(marker) }
        let reportSize = #"perl -e 'open(my $m, ">", $ARGV[0]); print $m ((stat(STDOUT))[7])'"#
        let script = "head -c 100000 /dev/zero | tr '\\0' x; echo; (sleep 0.5; echo tick; \(reportSize) \(marker)) & echo port 59095"
        let result = try await sh(script, output: .file)
        #expect(result.stdout.contains("port 59095"))
        #expect(result.stdout.count > 100_000)

        for _ in 0..<300 where !FileManager.default.fileExists(atPath: marker) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        let size = try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the grandchild's "tick\n" is left.
        #expect(size == "5")
    }

    @Test func killsAChildThatOverrunsItsTimeout() async throws {
        let result = try await sh("echo partial; exec sleep 30", timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(result.stdout == "partial\n")
    }

    @Test func cancellingKillsTheChildsChildrenToo() async throws {
        let grandchild = Mutex<pid_t?>(nil)
        let run = Task {
            try await ChildProcess.run(
                executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"], timeout: .seconds(20)
            ) { text in
                if let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { grandchild.withLock { $0 = pid } }
            }
        }
        for _ in 0..<500 where grandchild.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(grandchild.withLock { $0 })
        #expect(kill(pid, 0) == 0)

        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        // Orphaned, the grandchild is reaped by launchd once it dies.
        for _ in 0..<300 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(pid, 0) == -1)
    }

    @Test func deliversEachNewPieceOfOutputOnce() async throws {
        let pieces = Mutex<[String]>([])
        let result = try await ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", "printf one; sleep 0.3; printf two"], timeout: .seconds(10)
        ) { text in pieces.withLock { $0.append(text) } }
        let delivered = pieces.withLock { $0 }
        #expect(delivered.joined() == "onetwo")
        #expect(delivered.count == 2)
        #expect(result.stdout == "onetwo")
    }

    @Test func holdsBackACharacterCutOffMidSequence() {
        let euro = Data("€".utf8)
        #expect(UTF8Prefix.completeLength(of: Data("ab".utf8) + euro.prefix(2)) == 2)
        #expect(UTF8Prefix.completeLength(of: Data("ab".utf8) + euro) == 5)
        #expect(UTF8Prefix.completeLength(of: Data()) == 0)
    }

    @Test func passesInputEnvironmentAndWorkingDirectory() throws {
        let directory = "/usr/bin"
        let result = try ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", "cat; echo \"$PLUME_PROBE\"; pwd -P"],
            environment: ["PATH": "/bin:/usr/bin", "PLUME_PROBE": "probe"], workingDirectory: directory, input: .text("typed\n")
        )
        #expect(result.stdout == "typed\nprobe\n\(directory)\n")
    }

    @Test func aChildThatIgnoresItsInputDoesNotBlockTheRun() throws {
        let result = try ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", "exit 0"], input: .text(String(repeating: "x", count: 1_000_000))
        )
        #expect(result.status == 0)
    }

    @Test func aMissingExecutableThrows() {
        #expect(throws: ChildProcessError.self) {
            try ChildProcess.run(executable: "/nonexistent/plume-probe", arguments: [])
        }
    }

    @Test func capturedOutputReturnsStdout() {
        #expect(ChildProcess.capturedOutput(executable: "/bin/sh", arguments: ["-c", "echo hi; echo err >&2"], timeout: 5) == "hi\n")
    }

    @Test func capturedOutputIsNilOnATimeoutEvenWhenABackgroundedHelperHoldsTheOutput() {
        let start = Date()
        let output = ChildProcess.capturedOutput(
            executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo partial; sleep 30"], timeout: 0.5
        )
        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func lineSplitterReturnsOnlyCompletedLines() {
        var buffer = LineSplitter()
        #expect(buffer.completeLines(appending: "New reservation created with id 3f3j").isEmpty)
        #expect(buffer.completeLines(appending: "pxdv5lw6y. Ends\nWaiting") == ["New reservation created with id 3f3jpxdv5lw6y. Ends"])
        #expect(buffer.completeLines(appending: "...\n") == ["Waiting..."])
    }
}
