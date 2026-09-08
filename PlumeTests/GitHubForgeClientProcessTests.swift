import Testing
import Foundation
@testable import Plume

/// The subprocess plumbing, exercised against harmless commands rather than
/// `gh` — these must pass with no network and no GitHub auth.
struct GitHubForgeClientProcessTests {
    /// The shape `runGH` launches.
    private func launch(_ command: String) -> (process: Process, stdout: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-mc", LoginShellCommand.wrap("exec " + command)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        return (process, output)
    }

    private func read(_ pipe: Pipe) -> String {
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A login shell is the only thing that finds a Homebrew binary from a
    /// GUI-launched app, so the wrap has to survive into a real PATH lookup.
    @Test func theLoginShellResolvesABinaryByPath() throws {
        let (process, output) = launch("command -v git")
        try process.run()
        let stdout = read(output)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(stdout.hasSuffix("git"))
    }

    /// `-m` puts the command in a process group led by the child, which is
    /// what `kill(-pid)` needs.
    @Test func theCommandLeadsItsOwnProcessGroup() throws {
        let (process, output) = launch("echo $$")
        try process.run()
        let stdout = read(output)
        process.waitUntilExit()
        #expect(Int32(stdout) == process.processIdentifier)
    }

    /// Killing only the process leaves `gh` holding the pipe's write end, so
    /// the read blocks for as long as the command would have taken and the
    /// deadline buys nothing. The group kill is what actually bounds it.
    @Test func aHungCommandIsBoundedByItsDeadline() throws {
        let (process, output) = launch("sleep 30")
        let started = Date()
        try process.run()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            kill(-pid, SIGKILL)
        }
        _ = read(output)
        process.waitUntilExit()

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10, "read blocked for \(elapsed)s — the kill did not reach the command")
        #expect(process.terminationStatus != 0)
    }

    @Test func aHungCommandLeavesNoSurvivor() throws {
        let marker = "plume-forge-probe-\(UUID().uuidString)"
        let (process, output) = launch("sleep 30 # \(marker)")
        try process.run()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            kill(-pid, SIGKILL)
        }
        _ = read(output)
        process.waitUntilExit()

        #expect(runningProcesses().contains(marker) == false)
    }

    private func runningProcesses() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "command"]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = Pipe()
        try? ps.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func aTimeoutIsDistinctFromAPlainFailure() {
        #expect(PullRequestFetchState.failing(ForgeError(message: "x", kind: .timedOut)) == .timedOut)
        #expect(PullRequestFetchState.failing(ForgeError(message: "x")) == .failed("x"))
    }
}
