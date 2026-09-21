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
