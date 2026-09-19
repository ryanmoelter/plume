import Foundation
import Testing
@testable import Plume

struct CommandModeRunnerTests {
    @Test func capturesStandardOutput() async {
        let result = await CommandModeRunner.run("echo hello", in: nil)
        #expect(result.stdout == "hello")
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    /// A failing command is an ordinary outcome whose exit code the agent
    /// should see, unlike `GitRunner`, which throws on one.
    @Test func reportsANonzeroExitWithoutThrowing() async {
        let result = await CommandModeRunner.run("exit 3", in: nil)
        #expect(result.exitCode == 3)
    }

    @Test func keepsTheTwoStreamsApart() async {
        let result = await CommandModeRunner.run("echo out; echo err >&2", in: nil)
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }

    @Test func runsInTheGivenDirectory() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await CommandModeRunner.run("pwd", in: directory.path)
        // The temporary directory resolves through a symlink on macOS.
        #expect(result.stdout.hasSuffix(directory.lastPathComponent))
    }

    @Test func truncatesOutputPastTheLineCap() {
        let output = (1...(CommandModeRunner.maximumOutputLines + 50))
            .map(String.init)
            .joined(separator: "\n")
        let truncated = CommandModeRunner.truncated(output)
        #expect(truncated.hasSuffix("…output truncated"))
        #expect(truncated.split(separator: "\n").count < output.split(separator: "\n").count)
    }

    @Test func truncatesOutputPastTheByteCap() {
        let truncated = CommandModeRunner.truncated(
            String(repeating: "x", count: CommandModeRunner.maximumOutputBytes + 100)
        )
        #expect(truncated.hasSuffix("…output truncated"))
    }

    @Test func leavesShortOutputAlone() {
        #expect(CommandModeRunner.truncated("hello") == "hello")
    }

    /// The exact shape Claude Code's own bash mode writes, from a captured
    /// `!echo hello` session — the whole point of the tags is that the agent
    /// and `InjectedContent` both already understand them.
    @Test func transcriptTextMatchesTheCLIsBashModeFormat() {
        let result = CommandModeResult(command: "echo hello", stdout: "hello", stderr: "", exitCode: 0)
        #expect(result.transcriptText == """
        <bash-input>echo hello</bash-input>
        <bash-stdout>hello</bash-stdout><bash-stderr></bash-stderr>
        """)
    }

    /// Plume renders its own sent text back through the same classifier the
    /// transcript goes through, so a format drift would show as raw XML.
    @Test func transcriptTextIsClassifiedAsAShellCommand() {
        let result = CommandModeResult(command: "ls", stdout: "a", stderr: "", exitCode: 0)
        let first = result.transcriptText
            .split(separator: "\n", maxSplits: 1)
            .map(String.init)[0]
        #expect(InjectedContent.classify(text: first, isMeta: false) == .shellCommand(command: "ls"))
    }

    @Test func emptyOutputStillWritesBothTags() {
        let result = CommandModeResult(command: "true", stdout: "", stderr: "", exitCode: 0)
        #expect(result.transcriptText.contains("<bash-stdout></bash-stdout>"))
        #expect(result.transcriptText.contains("<bash-stderr></bash-stderr>"))
    }

    @Test func stderrIsCarriedInItsOwnTag() {
        let result = CommandModeResult(command: "false", stdout: "", stderr: "nope", exitCode: 1)
        #expect(result.transcriptText.contains("<bash-stderr>nope</bash-stderr>"))
    }
}
