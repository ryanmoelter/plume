import Foundation
import Testing
@testable import Plume

/// `plume init zsh` carries wt's completion and the `plume()` wrapper that
/// turns `plume wt switch` into a `cd`; `--aliases` adds a bare `wt()`.
/// Ported from the wt half of `test_init.py`.
struct WTInitTests {
    private func parses(_ script: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", "-c", script]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func lines(_ script: String) -> [String] {
        script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func wtIsACompletedSubcommand() {
        #expect(ShellIntegration.commands.contains { $0.name == "wt" })
        #expect(ShellIntegration.zsh().contains("    wt)\n"))
    }

    @Test func theScriptDefinesThePlumeWrapper() {
        #expect(lines(ShellIntegration.zsh()).contains("plume() {"))
    }

    /// The wrapper must ask for `wt path`, not `wt switch`: reaching the
    /// binary's `switch` is the error that tells users to install it.
    @Test func theWrapperDelegatesToPath() {
        #expect(ShellIntegration.zsh().contains("command plume wt path"))
    }

    @Test func noBareWtFunctionWithoutAliases() {
        let script = lines(ShellIntegration.zsh())
        #expect(!script.contains("wt() {"))
        #expect(!script.contains { $0.hasPrefix("compdef ") && $0.hasSuffix(" wt") })
    }

    @Test func aliasesAddABareWtFunctionAndItsCompletion() {
        let script = lines(ShellIntegration.zsh(aliases: true))
        #expect(script.contains("wt() {"))
        #expect(script.contains { $0.hasPrefix("compdef ") && $0.hasSuffix(" wt") })
    }

    /// The script is eval'd at shell startup, so a quoting slip would break
    /// every new shell.
    @Test(arguments: [false, true])
    func theScriptParses(_ aliases: Bool) throws {
        #expect(try parses(ShellIntegration.zsh(aliases: aliases)))
    }

    /// `init` belongs to `plume`, which needs no repository.
    @Test func wtInitPointsAtPlumeInit() {
        let console = BufferConsole()
        let status = WT.main(["init", "zsh"], environment: [:], console: console, version: "1.0")
        #expect(status != 0)
        #expect(console.stderr.contains("plume init zsh"))
    }

    @Test func versionRunsOutsideARepository() {
        let console = BufferConsole()
        #expect(WT.main(["--version"], environment: [:], console: console, version: "1.0") == 0)
        #expect(console.stdout.hasPrefix("wt "))
    }
}
