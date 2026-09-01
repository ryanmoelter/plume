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
}
