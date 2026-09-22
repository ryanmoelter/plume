import Foundation
import Testing
@testable import Plume

struct ShellTranscriptTests {
    @Test func readsACommandAndItsOutputFromOneLine() {
        let shell = ShellTranscript.parse("""
        <bash-input>echo hello</bash-input>
        <bash-stdout>hello</bash-stdout><bash-stderr></bash-stderr>
        """)
        #expect(shell.command == "echo hello")
        #expect(shell.output == "hello")
    }

    /// Claude Code's own bash mode writes the two halves as separate lines.
    @Test func readsEitherHalfOnItsOwn() {
        #expect(ShellTranscript.parse("<bash-input>ls</bash-input>") == ShellTranscript(command: "ls"))
        #expect(
            ShellTranscript.parse("<bash-stdout>a</bash-stdout><bash-stderr></bash-stderr>")
                == ShellTranscript(output: "a")
        )
    }

    @Test func anythingOnStderrReadsAsAFailure() {
        // The transcript records no exit code, so stderr is the only signal
        // a parsed line carries.
        #expect(ShellTranscript.parse("<bash-stdout>out</bash-stdout><bash-stderr>boom</bash-stderr>").didFail)
        #expect(!ShellTranscript.parse("<bash-stdout>out</bash-stdout><bash-stderr></bash-stderr>").didFail)
        #expect(!ShellTranscript.parse("<bash-input>ls</bash-input>").didFail)
    }

    @Test func joinsStderrBelowStdout() {
        let shell = ShellTranscript.parse("<bash-stdout>out</bash-stdout><bash-stderr>err</bash-stderr>")
        #expect(shell.output == "out\nerr")
    }

    @Test func emptyOutputTagsLeaveNoOutputBlock() {
        let shell = ShellTranscript.parse("""
        <bash-input>true</bash-input>
        <bash-stdout></bash-stdout><bash-stderr></bash-stderr>
        """)
        #expect(shell.output == nil)
        #expect(!shell.isEmpty)
    }

    @Test func prosewithNoTagsIsEmpty() {
        #expect(ShellTranscript.parse("just words").isEmpty)
    }

    /// The command runs through the same parse the row does, so a command
    /// containing the tag's own characters still reads back whole.
    @Test func keepsAngleBracketsInsideTheCommand() {
        let shell = ShellTranscript.parse("<bash-input>echo a > b.txt</bash-input>")
        #expect(shell.command == "echo a > b.txt")
    }
}

/// The exit code Plume's command mode writes, and what a line without one
/// falls back to.
@MainActor
struct ShellExitCodeTests {
    private func result(stdout: String = "", stderr: String = "", exitCode: Int32) -> CommandModeResult {
        CommandModeResult(command: "ls", stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    @Test func aZeroExitParsesAsSuccess() {
        let shell = ShellTranscript.parse(result(stdout: "foo", exitCode: 0).transcriptText)

        #expect(shell.exitCode == 0)
        #expect(!shell.didFail)
    }

    @Test func aNonzeroExitParsesAsFailure() {
        let shell = ShellTranscript.parse(result(stderr: "nope", exitCode: 1).transcriptText)

        #expect(shell.exitCode == 1)
        #expect(shell.didFail)
    }

    /// The whole point of sending the code: a command that chats on stderr
    /// and exits zero is not a failure, which the stderr guess got wrong.
    @Test func stderrWithAZeroExitIsNotAFailure() {
        let shell = ShellTranscript.parse(result(stderr: "downloading…", exitCode: 0).transcriptText)

        #expect(!shell.didFail)
    }

    /// And the reverse: a silent failure is still a failure.
    @Test func aNonzeroExitWithNoOutputStillFails() {
        let shell = ShellTranscript.parse(result(exitCode: 2).transcriptText)

        #expect(shell.exitCode == 2)
        #expect(shell.didFail)
    }

    /// Claude Code's own bash mode writes no exit tag, so those lines keep
    /// the stderr heuristic rather than reading as a success.
    @Test func aLineWithNoExitTagFallsBackToStderr() {
        let withStderr = ShellTranscript.parse(
            "<bash-input>ls</bash-input>\n<bash-stdout></bash-stdout><bash-stderr>boom</bash-stderr>"
        )
        #expect(withStderr.exitCode == nil)
        #expect(withStderr.didFail)

        let clean = ShellTranscript.parse(
            "<bash-input>ls</bash-input>\n<bash-stdout>foo</bash-stdout><bash-stderr></bash-stderr>"
        )
        #expect(clean.exitCode == nil)
        #expect(!clean.didFail)
    }

    @Test func theCommandAndOutputStillParseAlongsideTheExitCode() {
        let shell = ShellTranscript.parse(result(stdout: "foo", stderr: "bar", exitCode: 1).transcriptText)

        #expect(shell.command == "ls")
        #expect(shell.output == "foo\nbar")
    }
}
