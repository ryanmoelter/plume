import Testing
import Foundation
@testable import Plume

struct ClaudeCodeProviderTests {
    private let provider = ClaudeCodeProvider()

    /// Wraps a `claude` argv string the way `ClaudeCodeProvider` should: the
    /// whole thing runs as one argument to a login, interactive shell, so
    /// `claude` (which reaches `PATH` only via the user's shell profile) is
    /// found the same way it would be in a normal terminal.
    private func loginWrapped(_ inner: String) -> String {
        LoginShellCommand.wrap(inner)
    }

    @Test func firstMessageIsQuotedAsASingleArgument() {
        let launch = provider.launchCommand(firstMessage: "fix the login bug", resumeSessionID: nil)
        #expect(launch.command == loginWrapped("claude 'fix the login bug'"))
    }

    @Test func resumePassesTheSessionID() {
        let launch = provider.launchCommand(firstMessage: nil, resumeSessionID: "abc-123")
        #expect(launch.command == loginWrapped("claude --resume 'abc-123'"))
    }

    @Test func resumeWithAMessageSendsBoth() {
        let launch = provider.launchCommand(firstMessage: "continue", resumeSessionID: "abc-123")
        #expect(launch.command == loginWrapped("claude --resume 'abc-123' 'continue'"))
    }

    @Test func noArgumentsStartsAPlainSession() {
        #expect(provider.launchCommand(firstMessage: nil, resumeSessionID: nil).command == loginWrapped("claude"))
    }

    @Test func blankMessageIsOmitted() {
        #expect(provider.launchCommand(firstMessage: "   ", resumeSessionID: nil).command == loginWrapped("claude"))
    }

    @Test func messageIsTrimmed() {
        let launch = provider.launchCommand(firstMessage: "  hello  ", resumeSessionID: nil)
        #expect(launch.command == loginWrapped("claude 'hello'"))
    }

    /// A message is arbitrary user text; it must never be able to end the
    /// quoted argument and run something else.
    @Test func quotesInAMessageCannotEscapeTheArgument() {
        let launch = provider.launchCommand(
            firstMessage: "it's here'; rm -rf /; echo '", resumeSessionID: nil
        )
        #expect(launch.command == loginWrapped(#"claude 'it'\''s here'\''; rm -rf /; echo '\'''"#))
    }

    @Test func shellMetacharactersStayInsideTheArgument() {
        let launch = provider.launchCommand(firstMessage: "$(whoami) && `id` | tee", resumeSessionID: nil)
        #expect(launch.command == loginWrapped("claude '$(whoami) && `id` | tee'"))
    }

    @Test func providerIdentifiesItself() {
        #expect(provider.id == ClaudeCodeProviderID)
    }

    @Test func taskAndTabIDsInjectEnvironment() {
        let taskID = UUID()
        let tabID = UUID()
        let launch = provider.launchCommand(
            firstMessage: nil, resumeSessionID: nil, taskID: taskID, tabID: tabID
        )
        #expect(launch.environment["PLUME_TASK_ID"] == taskID.uuidString)
        #expect(launch.environment["PLUME_TAB_ID"] == tabID.uuidString)
        #expect(launch.environment["PLUME_EVENTS_DIR"] == AppPaths.eventsDirectory.path)
    }

    @Test func missingTaskOrTabIDOmitsEnvironment() {
        let launch = provider.launchCommand(
            firstMessage: nil, resumeSessionID: nil, taskID: nil, tabID: UUID()
        )
        #expect(launch.environment.isEmpty)
    }

    @Test func resumeViaTheFourArgumentOverloadStillQuotesTheSessionID() {
        let launch = provider.launchCommand(
            firstMessage: nil, resumeSessionID: "abc-123", taskID: nil, tabID: nil
        )
        #expect(launch.command == loginWrapped("claude --resume 'abc-123'"))
    }
}
