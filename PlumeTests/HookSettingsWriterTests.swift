import Testing
import Foundation
@testable import Plume

struct HookSettingsWriterTests {
    private func hooks() throws -> [String: Any] {
        try #require(HookSettingsWriter.settingsJSON()["hooks"] as? [String: Any])
    }

    @Test func coversTheEventsStatusIsDerivedFrom() throws {
        let hooks = try hooks()
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse",
                      "Stop", "SubagentStop", "Notification", "SessionEnd"] {
            #expect(hooks[event] != nil, "missing hook for \(event)")
        }
    }

    /// Claude Code rejects a matcher on Stop and UserPromptSubmit; for the
    /// rest, omitting it already means "all".
    @Test func noEntryDeclaresAMatcher() throws {
        for (event, value) in try hooks() {
            let groups = try #require(value as? [[String: Any]])
            for group in groups {
                #expect(group["matcher"] == nil, "\(event) should not declare a matcher")
            }
        }
    }

    @Test func everyHookIsACommandHook() throws {
        for (_, value) in try hooks() {
            let groups = try #require(value as? [[String: Any]])
            let handlers = try #require(groups.first?["hooks"] as? [[String: String]])
            #expect(handlers.first?["type"] == "command")
            #expect(handlers.first?["command"] == HookSettingsWriter.hookCommand)
        }
    }

    @Test func theCommandAppendsToThePerTabFile() {
        let command = HookSettingsWriter.hookCommand
        #expect(command.contains("mkdir -p"))
        #expect(command.contains(">>"))
        #expect(command.contains("$PLUME_EVENTS_DIR"))
        #expect(command.contains("$PLUME_TASK_ID"))
        #expect(command.contains("$PLUME_TAB_ID"))
    }

    @Test func producesValidJSONOnDisk() throws {
        let url = try HookSettingsWriter.write()
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["hooks"] != nil)
    }
}

struct InstrumentedLaunchTests {
    /// The whole `claude` argv runs as one argument to a login, interactive
    /// shell — see `LoginShellCommand`.
    private func loginWrapped(_ inner: String) -> String {
        LoginShellCommand.wrap(inner)
    }

    @Test func launchPassesSettingsAndIdentifiers() {
        let taskID = UUID()
        let tabID = UUID()
        let provider = ClaudeCodeProvider(settingsPath: "/tmp/settings.json")

        let launch = provider.launchCommand(
            firstMessage: "hi", resumeSessionID: nil, taskID: taskID, tabID: tabID
        )

        #expect(launch.command == loginWrapped("claude --settings '/tmp/settings.json' 'hi'"))
        #expect(launch.environment["PLUME_TASK_ID"] == taskID.uuidString)
        #expect(launch.environment["PLUME_TAB_ID"] == tabID.uuidString)
        #expect(launch.environment["PLUME_EVENTS_DIR"] == AppPaths.eventsDirectory.path)
    }

    @Test func settingsPathIsQuoted() {
        let provider = ClaudeCodeProvider(settingsPath: "/tmp/a b/settings.json")
        let launch = provider.launchCommand(firstMessage: nil, resumeSessionID: nil)
        #expect(launch.command == loginWrapped("claude --settings '/tmp/a b/settings.json'"))
    }

    /// Without instrumentation the agent must still launch, just unreported.
    @Test func withoutSettingsItDegradesToAPlainLaunch() {
        let launch = ClaudeCodeProvider().launchCommand(firstMessage: "hi", resumeSessionID: nil)
        #expect(launch.command == loginWrapped("claude 'hi'"))
        #expect(launch.environment["PLUME_TASK_ID"] == nil)
        #expect(launch.environment["PLUME_TAB_ID"] == nil)
        #expect(launch.environment["PLUME_EVENTS_DIR"] == nil)
    }

    @Test func resumeKeepsInstrumentation() {
        let provider = ClaudeCodeProvider(settingsPath: "/s.json")
        let launch = provider.launchCommand(
            firstMessage: nil, resumeSessionID: "sess-1", taskID: UUID(), tabID: UUID()
        )
        #expect(launch.command == loginWrapped("claude --settings '/s.json' --resume 'sess-1'"))
    }

    @Test func eventsFilePathIsPerTaskAndTab() {
        let taskID = UUID()
        let tabID = UUID()
        let path = AppPaths.eventsFile(taskID: taskID, tabID: tabID).path
        #expect(path.hasSuffix("/\(taskID.uuidString)/\(tabID.uuidString).jsonl"))
    }
}
