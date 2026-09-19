import Foundation
import Testing
@testable import Plume

struct CommandModeRunnerTests {
    @Test func capturesStandardOutput() async {
        let result = await CommandModeRunner.run("echo hello", in: nil)
        #expect(result.output == "hello")
        #expect(result.exitCode == 0)
    }

    /// A failing command is an ordinary outcome whose exit code the agent
    /// should see, unlike `GitRunner`, which throws on one.
    @Test func reportsANonzeroExitWithoutThrowing() async {
        let result = await CommandModeRunner.run("exit 3", in: nil)
        #expect(result.exitCode == 3)
    }

    @Test func capturesStandardError() async {
        let result = await CommandModeRunner.run("echo oops >&2", in: nil)
        #expect(result.output == "oops")
    }

    @Test func runsInTheGivenDirectory() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await CommandModeRunner.run("pwd", in: directory.path)
        // The temporary directory resolves through a symlink on macOS.
        #expect(result.output.hasSuffix(directory.lastPathComponent))
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

    @Test func transcriptTextCarriesTheCommandAndItsOutput() {
        let result = CommandModeResult(command: "echo hi", output: "hi", exitCode: 0)
        #expect(result.transcriptText.hasPrefix("!echo hi"))
        #expect(result.transcriptText.contains("hi"))
        #expect(!result.transcriptText.contains("exit"))
    }

    @Test func transcriptTextReportsANonzeroExit() {
        let result = CommandModeResult(command: "false", output: "", exitCode: 1)
        #expect(result.transcriptText.contains("exit 1"))
    }

    @Test func transcriptTextSaysSoWhenNothingWasPrinted() {
        let result = CommandModeResult(command: "true", output: "", exitCode: 0)
        #expect(result.transcriptText.contains("(no output)"))
    }
}
