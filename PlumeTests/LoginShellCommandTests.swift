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
        let environment = LoginShellCommand.plumeEnvironment(
            taskID: taskID, tabID: tabID, socketPath: "/serving/cli.sock", bundleID: "com.example.Plume.debug"
        )
        #expect(environment["PLUME"] == "1")
        #expect(environment["PLUME_BUNDLE_ID"] == "com.example.Plume.debug")
        #expect(environment["PLUME_TASK_ID"] == taskID.uuidString)
        #expect(environment["PLUME_TAB_ID"] == tabID.uuidString)
        #expect(environment["PLUME_SOCKET"] == "/serving/cli.sock")
        #expect(LoginShellCommand.sharedPlumeEnvironment(socketPath: "/serving/cli.sock", bundleID: nil)["PLUME_TAB_ID"] == nil)
    }

    @Test func aTabWithNoTaskStillExportsItsTab() {
        let tabID = UUID()
        let environment = LoginShellCommand.plumeEnvironment(taskID: nil, tabID: tabID, socketPath: "/serving/cli.sock", bundleID: nil)
        #expect(environment["PLUME_TAB_ID"] == tabID.uuidString)
        #expect(environment["PLUME_TASK_ID"] == nil)
        #expect(environment["PLUME_SOCKET"] == "/serving/cli.sock")
    }

    @Test func noSocketIsExportedWhenTheServerIsNotServing() {
        let environment = LoginShellCommand.plumeEnvironment(taskID: UUID(), tabID: UUID(), socketPath: nil, bundleID: nil)
        #expect(environment["PLUME_SOCKET"] == nil)
        #expect(environment["PLUME_TAB_ID"] != nil)
        #expect(LoginShellCommand.sharedPlumeEnvironment(socketPath: nil, bundleID: nil) == ["PLUME": "1"])
    }

    /// A process serving many tabs still names the app, so `plume wt` reads
    /// this build's Projects settings.
    @Test func theSharedEnvironmentNamesTheBundleWithoutASocket() {
        let environment = LoginShellCommand.sharedPlumeEnvironment(socketPath: nil, bundleID: "com.example.Plume")
        #expect(environment == ["PLUME": "1", "PLUME_BUNDLE_ID": "com.example.Plume"])
        #expect(UserDefaultsProjectSettingsSource(environment: environment).suiteName == "com.example.Plume")
    }

    /// `plume wt`'s automatic Nerd Font mode turns off under a font the
    /// user chose, which may lack the icons.
    @Test func aCustomTerminalFontIsExportedOnlyWhenSet() {
        let custom = LoginShellCommand.plumeEnvironment(
            taskID: UUID(), tabID: UUID(), socketPath: nil, bundleID: nil, customTerminalFont: true
        )
        #expect(custom["PLUME_CUSTOM_TERMINAL_FONT"] == "1")
        #expect(NerdFontMode.usesNerdFont(.automatic, environment: custom) == false)

        let bundled = LoginShellCommand.plumeEnvironment(taskID: UUID(), tabID: UUID(), socketPath: nil, bundleID: nil)
        #expect(bundled["PLUME_CUSTOM_TERMINAL_FONT"] == nil)
        #expect(NerdFontMode.usesNerdFont(.automatic, environment: bundled))
        #expect(LoginShellCommand.instanceKeys.contains("PLUME_CUSTOM_TERMINAL_FONT"))
    }

    @MainActor
    @Test func theDefaultsExportThePathTheServerServes() {
        let served = CLIServer.shared.socketPath
        #expect(LoginShellCommand.plumeEnvironment(taskID: UUID(), tabID: UUID())["PLUME_SOCKET"] == served)
        #expect(LoginShellCommand.sharedPlumeEnvironment()["PLUME_SOCKET"] == served)
        #expect(LoginShellCommand.sharedPlumeEnvironment()["PLUME_BUNDLE_ID"] == Bundle.main.bundleIdentifier)
    }

    /// The test host is the app, so launch has already dropped any keys an
    /// enclosing Plume's tab handed it.
    @Test func aChildEnvironmentCarriesOnlyThisAppsInstanceKeys() {
        let environment = LoginShellCommand.childEnvironment(overrides: ["PLUME_SOCKET": "/mine.sock"])
        #expect(environment["PLUME_SOCKET"] == "/mine.sock")
        #expect(environment["PLUME_TAB_ID"] == nil)
        #expect(environment["PLUME_TASK_ID"] == nil)
        #expect(environment["PLUME_EVENTS_DIR"] == nil)
        #expect(environment["PLUME_BUNDLE_ID"] == nil)
        #expect(LoginShellCommand.instanceKeys.contains("PLUME_BUNDLE_ID"))
        #expect(environment["PATH"] != nil)
    }
}
