import Testing
import Foundation
@testable import Plume

struct HeadlessCommandTests {
    private func permissionModeToken(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--permission-mode") else { return nil }
        let tokenIndex = arguments.index(after: flagIndex)
        return arguments.indices.contains(tokenIndex) ? arguments[tokenIndex] : nil
    }

    @Test func passesPlanWhenResolvedToPlan() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .plan,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "plan")
    }

    @Test func passesAcceptEditsWhenResolvedToAcceptEdits() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .acceptEdits,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "acceptEdits")
    }

    @Test func passesAutoWhenResolvedToAuto() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .auto,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "auto")
    }

    @Test func passesBypassPermissionsWhenResolvedToBypassPermissions() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: .bypassPermissions,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "bypassPermissions")
    }

    /// `.acceptEdits` is the floor when resolution comes back with nothing —
    /// not Plume's preferred mode, just what keeps a `-p` session out of
    /// Manual.
    @Test func fallsBackToAcceptEditsWhenResolutionIsNil() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil
        )
        #expect(permissionModeToken(in: arguments) == "acceptEdits")
    }
}

/// `--model` carries the tab's pre-launch choice, so the first turn runs on
/// the model the user picked rather than the CLI's default.
struct HeadlessCommandModelTests {
    private func modelToken(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--model") else { return nil }
        let tokenIndex = arguments.index(after: flagIndex)
        return arguments.indices.contains(tokenIndex) ? arguments[tokenIndex] : nil
    }

    @Test func passesTheChosenModel() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil,
            model: .opus
        )
        #expect(modelToken(in: arguments) == AgentModel.opus.id)
    }

    /// The bare aliases resolve to the 200K models, so the top-level menu's
    /// picks have to reach `--model` as explicit `[1m]` IDs.
    @Test(arguments: [
        (AgentModel.opus, "claude-opus-5[1m]"),
        (AgentModel.sonnet, "claude-sonnet-5[1m]"),
        (AgentModel.fable, "claude-fable-5-1"),
    ])
    func passesTheOneMillionIDForTheTopLevelPresets(model: AgentModel, expected: String) {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil,
            model: model
        )
        #expect(modelToken(in: arguments) == expected)
    }

    /// A model ID typed into the menu's "Other…" field reaches the command
    /// line intact, so the picker isn't limited to this build's list.
    @Test func passesAnUnknownModelIDVerbatim() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil,
            model: AgentModel(unrecognizedID: "claude-next-7")
        )
        #expect(modelToken(in: arguments) == "claude-next-7")
    }

    /// No choice means no flag, so the CLI keeps its own default rather than
    /// being pinned to a guess Plume invented.
    @Test func omitsTheFlagWhenNoModelIsChosen() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil,
            model: nil
        )
        #expect(!arguments.contains("--model"))
    }

    /// A bare `--resume` restores the model the conversation already used, so
    /// replaying an unchosen snapshot could only override a model changed
    /// elsewhere. See "Model on resume" in docs/headless-protocol.md.
    @Test func omitsTheFlagWhenResumingWithAnUnchosenModel() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: "session-1",
            permissionMode: nil,
            settingsPath: nil,
            model: .sonnet,
            isModelExplicitlyChosen: false
        )
        #expect(!arguments.contains("--model"))
        #expect(arguments.contains("--resume"))
    }

    @Test func passesTheFlagWhenResumingAfterTheUserPickedAModel() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: "session-1",
            permissionMode: nil,
            settingsPath: nil,
            model: .opus,
            isModelExplicitlyChosen: true
        )
        #expect(modelToken(in: arguments) == AgentModel.opus.id)
    }

    /// The rule is about resuming only: a cold launch has no conversation to
    /// restore from, so the snapshot is the best guess available.
    @Test func passesAnUnchosenModelOnAColdLaunch() {
        let arguments = HeadlessCommand.arguments(
            resumeSessionID: nil,
            permissionMode: nil,
            settingsPath: nil,
            model: .sonnet,
            isModelExplicitlyChosen: false
        )
        #expect(modelToken(in: arguments) == AgentModel.sonnet.id)
    }
}

/// Locks down the login-shell wrap that puts `claude` on PATH. A GUI-launched
/// app inherits launchd's minimal PATH, so exec'ing `claude` directly fails
/// with "No such file or directory" even though a terminal finds it.
struct HeadlessLoginShellCommandTests {
    @Test func argumentsRunThroughALoginShell() {
        let command = HeadlessCommand.loginShellCommand(arguments: ["claude", "-p"])
        #expect(command.contains("-lic"))
    }

    /// Each argument must reach the program as its own word, unmangled — a
    /// spaced settings path and the JSON-ish stream-json tokens are the ones
    /// at risk from the trip through two shells.
    @Test func everyArgumentSurvivesAsASeparateWord() throws {
        let arguments = [
            "-p",
            "--output-format", "stream-json",
            "--settings", "/tmp/a b/settings.json",
            "--permission-prompt-tool", "stdio"
        ]
        // `printf` stands in for `claude`, so what gets asserted is the real
        // wrap's word splitting rather than a stubbed command string.
        let command = HeadlessCommand.loginShellCommand(
            arguments: ["printf", "%s\\n"] + arguments
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let words = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        #expect(words == arguments)
    }
}
