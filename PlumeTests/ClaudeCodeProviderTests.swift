import Testing
import Foundation
@testable import Plume

struct ClaudeCodeProviderTests {
    private let provider = ClaudeCodeProvider()

    @Test func firstMessageIsQuotedAsASingleArgument() {
        let launch = provider.launchCommand(firstMessage: "fix the login bug", resumeSessionID: nil)
        #expect(launch.command == "claude 'fix the login bug'")
    }

    @Test func resumePassesTheSessionID() {
        let launch = provider.launchCommand(firstMessage: nil, resumeSessionID: "abc-123")
        #expect(launch.command == "claude --resume 'abc-123'")
    }

    @Test func resumeWithAMessageSendsBoth() {
        let launch = provider.launchCommand(firstMessage: "continue", resumeSessionID: "abc-123")
        #expect(launch.command == "claude --resume 'abc-123' 'continue'")
    }

    @Test func noArgumentsStartsAPlainSession() {
        #expect(provider.launchCommand(firstMessage: nil, resumeSessionID: nil).command == "claude")
    }

    @Test func blankMessageIsOmitted() {
        #expect(provider.launchCommand(firstMessage: "   ", resumeSessionID: nil).command == "claude")
    }

    @Test func messageIsTrimmed() {
        let launch = provider.launchCommand(firstMessage: "  hello  ", resumeSessionID: nil)
        #expect(launch.command == "claude 'hello'")
    }

    /// A message is arbitrary user text; it must never be able to end the
    /// quoted argument and run something else.
    @Test func quotesInAMessageCannotEscapeTheArgument() {
        let launch = provider.launchCommand(
            firstMessage: "it's here'; rm -rf /; echo '", resumeSessionID: nil
        )
        #expect(launch.command == #"claude 'it'\''s here'\''; rm -rf /; echo '\'''"#)
    }

    @Test func shellMetacharactersStayInsideTheArgument() {
        let launch = provider.launchCommand(firstMessage: "$(whoami) && `id` | tee", resumeSessionID: nil)
        #expect(launch.command == "claude '$(whoami) && `id` | tee'")
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
        #expect(launch.command == "claude --resume 'abc-123'")
    }
}
