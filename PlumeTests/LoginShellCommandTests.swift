import Testing
import Foundation
@testable import Plume

struct LoginShellCommandTests {
    @Test func wrapsWithTheGivenShellAsALoginInteractiveShell() {
        #expect(LoginShellCommand.wrap("claude 'hello'", shell: "/bin/zsh") == "/bin/zsh -lic 'claude '\\''hello'\\'''")
    }

    @Test func fallsBackToZshWhenShellIsNil() {
        #expect(LoginShellCommand.wrap("claude", shell: nil) == "/bin/zsh -lic 'claude'")
    }

    @Test func fallsBackToZshWhenShellIsEmpty() {
        #expect(LoginShellCommand.wrap("claude", shell: "") == "/bin/zsh -lic 'claude'")
    }

    @Test func honorsAnExplicitNonDefaultShell() {
        #expect(LoginShellCommand.wrap("claude", shell: "/opt/homebrew/bin/fish") == "/opt/homebrew/bin/fish -lic 'claude'")
    }

    /// The inner command is quoted as a single argument, so its own quoting
    /// and shell metacharacters cannot escape into the outer `-lic` shell.
    @Test func innerCommandQuotingSurvivesTheOuterWrap() {
        let inner = "claude --settings '/tmp/a b.json' 'it'\\''s a message; rm -rf /'"
        let wrapped = LoginShellCommand.wrap(inner, shell: "/bin/zsh")
        #expect(wrapped == "/bin/zsh -lic \(shellQuoted(inner))")
    }

    @Test func loginShellWithNoInnerCommand() {
        #expect(LoginShellCommand.loginShell(shell: "/bin/zsh") == "/bin/zsh -li")
    }

    @Test func loginShellFallsBackToZsh() {
        #expect(LoginShellCommand.loginShell(shell: nil) == "/bin/zsh -li")
    }

    @Test func plumeEnvironmentMarksTheShell() {
        #expect(LoginShellCommand.plumeEnvironment == ["PLUME": "1"])
    }

    @Test func aTabsEnvironmentNamesItsTabTaskAndSocket() {
        let taskID = UUID()
        let tabID = UUID()
        let environment = LoginShellCommand.plumeEnvironment(taskID: taskID, tabID: tabID, socketPath: "/serving/cli.sock")
        #expect(environment["PLUME"] == "1")
        #expect(environment["PLUME_TASK_ID"] == taskID.uuidString)
        #expect(environment["PLUME_TAB_ID"] == tabID.uuidString)
        #expect(environment["PLUME_SOCKET"] == "/serving/cli.sock")
        #expect(LoginShellCommand.sharedPlumeEnvironment(socketPath: "/serving/cli.sock")["PLUME_TAB_ID"] == nil)
    }

    @Test func noSocketIsExportedWhenTheServerIsNotServing() {
        let environment = LoginShellCommand.plumeEnvironment(taskID: UUID(), tabID: UUID(), socketPath: nil)
        #expect(environment["PLUME_SOCKET"] == nil)
        #expect(environment["PLUME_TAB_ID"] != nil)
        #expect(LoginShellCommand.sharedPlumeEnvironment(socketPath: nil) == ["PLUME": "1"])
    }

    @MainActor
    @Test func theDefaultsExportThePathTheServerServes() {
        let served = CLIServer.shared.socketPath
        #expect(LoginShellCommand.plumeEnvironment(taskID: UUID(), tabID: UUID())["PLUME_SOCKET"] == served)
        #expect(LoginShellCommand.sharedPlumeEnvironment()["PLUME_SOCKET"] == served)
    }

    /// The test host is the app, so launch has already dropped any keys an
    /// enclosing Plume's tab handed it.
    @Test func aChildEnvironmentCarriesOnlyThisAppsInstanceKeys() {
        let environment = LoginShellCommand.childEnvironment(overrides: ["PLUME_SOCKET": "/mine.sock"])
        #expect(environment["PLUME_SOCKET"] == "/mine.sock")
        #expect(environment["PLUME_TAB_ID"] == nil)
        #expect(environment["PLUME_TASK_ID"] == nil)
        #expect(environment["PLUME_EVENTS_DIR"] == nil)
        #expect(environment["PATH"] != nil)
    }
}
