import Testing
@testable import Plume

/// A chat that never started reports the process's own last stderr line, or a
/// bare exit status when even that is missing. A clean exit reports nothing.
struct ChatStartFailureTests {
    @Test func cleanExitIsNotAFailure() {
        #expect(ChatStartFailure.classify(error: nil, exitStatus: 0) == nil)
    }

    @Test func cleanExitIgnoresAStaleError() {
        #expect(ChatStartFailure.classify(error: "something earlier", exitStatus: 0) == nil)
    }

    @Test func nothingReportedIsNotAFailure() {
        #expect(ChatStartFailure.classify(error: nil, exitStatus: nil) == nil)
        #expect(ChatStartFailure.classify(error: "   ", exitStatus: nil) == nil)
    }

    @Test func nonzeroExitWithoutStderrReportsTheStatus() throws {
        let failure = try #require(ChatStartFailure.classify(error: nil, exitStatus: 127))

        #expect(failure.remedy == .retry)
        #expect(failure.detail == "Exit status 127.")
    }

    @Test(arguments: [
        "zsh: command not found: claude",
        "sh: claude: command not found",
        "/bin/zsh: line 1: claude: No such file or directory"
    ])
    func aMissingCLIAsksForAnInstall(_ line: String) throws {
        let failure = try #require(ChatStartFailure.classify(error: line, exitStatus: 127))

        #expect(failure.remedy == .installCLI)
        #expect(failure.detail == line)
    }

    /// A different missing binary must not claim the CLI is the absent one.
    @Test func anUnrelatedMissingBinaryStaysARetry() throws {
        let failure = try #require(
            ChatStartFailure.classify(error: "zsh: command not found: node", exitStatus: 127)
        )

        #expect(failure.remedy == .retry)
    }

    @Test func anyOtherStderrLinePassesThroughVerbatim() throws {
        let line = "Error: credit balance is too low"
        let failure = try #require(ChatStartFailure.classify(error: line, exitStatus: 1))

        #expect(failure.remedy == .retry)
        #expect(failure.detail == line)
        #expect(failure.title == "Claude Code couldn't start")
    }

    /// A pre-flight failure records no exit status, since no process ran.
    @Test func aPreflightFailureClassifiesWithoutAnExitStatus() throws {
        let failure = try #require(
            ChatStartFailure.classify(error: "claude: command not found", exitStatus: nil)
        )

        #expect(failure.remedy == .installCLI)
    }
}
