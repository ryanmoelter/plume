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
