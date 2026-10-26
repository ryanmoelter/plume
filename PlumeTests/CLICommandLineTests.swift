import Foundation
import Testing

@testable import Plume

/// `plume` argument parsing, including the `plume-notify` name and the flags
/// the old script accepted, and the OSC 777 fallback's sanitizing.
struct CLICommandLineTests {
    private func parse(_ arguments: [String], as name: String = "plume") throws -> CLIInvocation {
        try CLICommandLine.parse(arguments, executableName: name)
    }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try parse([]) == .help)
        #expect(try parse(["--version"]) == .version)
    }

    @Test func notifyTakesPositionalTitleAndBody() throws {
        #expect(try parse(["notify", "Done"]) == .notify(title: "Done", body: ""))
        #expect(try parse(["notify", "Done", "All green"]) == .notify(title: "Done", body: "All green"))
    }

    @Test func notifyTakesTheScriptsFlags() throws {
        #expect(try parse(["notify", "--title", "T", "--body", "B"]) == .notify(title: "T", body: "B"))
        #expect(try parse(["notify", "--title", "T", "--message", "M"]) == .notify(title: "T", body: "M"))
    }

    /// As in the script, `--` is skipped and the flags after it still parse.
    @Test func aDoubleDashDoesNotEndTheFlags() throws {
        #expect(try parse(["notify", "--", "--title", "T"]) == .notify(title: "T", body: ""))
        #expect(try parse(["notify", "T", "--", "B"]) == .notify(title: "T", body: "B"))
        #expect(throws: CLIUsageError.self) { try parse(["notify", "--", "--title"]) }
    }

    @Test func helpIsAUsageErrorUnderEitherName() {
        #expect(throws: CLIUsageError(message: nil, usage: CLICommandLine.notifyUsage)) {
            try parse(["notify", "-h"])
        }
        #expect(throws: CLIUsageError(message: nil, usage: CLICommandLine.notifyAliasUsage)) {
            try parse(["--help"], as: "plume-notify")
        }
        #expect(throws: CLIUsageError(message: nil, usage: CLICommandLine.notifyAliasUsage)) {
            try parse(["T", "-h"], as: "plume-notify")
        }
    }

    /// The script assigned fields in argument order, the first positional
    /// always to the title.
    @Test func mixedFlagsAndPositionalsApplyInOrderLikeTheScript() throws {
        #expect(try parse(["notify", "--title", "Build", "All green"]) == .notify(title: "All green", body: ""))
        #expect(try parse(["notify", "All green", "--title", "Build"]) == .notify(title: "Build", body: ""))
        #expect(try parse(["notify", "--body", "B", "T", "Late"]) == .notify(title: "T", body: "Late"))
        #expect(throws: CLIUsageError.self) { try parse(["notify", "--title", "T", "a", "b", "c"]) }
    }

    @Test func thePlumeNotifyNameSkipsTheSubcommand() throws {
        #expect(try parse(["Hi", "there"], as: "plume-notify") == .notify(title: "Hi", body: "there"))
    }

    @Test func notifyRejectsAMissingTitleOrExtraArguments() {
        #expect(throws: CLIUsageError.self) { try parse(["notify"]) }
        #expect(throws: CLIUsageError.self) { try parse(["notify", "a", "b", "c"]) }
        #expect(throws: CLIUsageError.self) { try parse(["notify", "--title"]) }
    }

    @Test func tabNewParsesItsOptions() throws {
        #expect(try parse(["tab", "new"]) == .newTab(directory: nil, taskID: nil, select: false))
        #expect(try parse(["tab", "new", "--cwd", "/tmp", "--task", "T", "--select"])
            == .newTab(directory: "/tmp", taskID: "T", select: true))
        #expect(throws: CLIUsageError.self) { try parse(["tab"]) }
        #expect(throws: CLIUsageError.self) { try parse(["tab", "new", "--bogus"]) }
    }

    @Test func presenceAndInitParse() throws {
        #expect(try parse(["presence"]) == .presence(json: false))
        #expect(try parse(["presence", "--json"]) == .presence(json: true))
        #expect(try parse(["init", "zsh"]) == .shellInit(aliases: false))
        #expect(try parse(["init", "zsh", "--aliases"]) == .shellInit(aliases: true))
        #expect(throws: CLIUsageError.self) { try parse(["init", "zsh", "--bogus"]) }
        #expect(throws: CLIUsageError.self) { try parse(["init", "bash"]) }
        #expect(throws: CLIUsageError.self) { try parse(["frobnicate"]) }
    }

    @Test func sanitizeKeepsTheEscapesFieldsIntact() {
        #expect(CLICommandLine.sanitize("a;b\u{07}c\nd\te") == "a,bc d e")
        #expect(CLICommandLine.sanitize("café ✓") == "café ✓")
    }

    @Test func theEscapeIsOSC777Notify() {
        #expect(CLICommandLine.osc777(title: "T;1", body: "B") == "\u{1B}]777;notify;T,1;B\u{07}")
    }

    @Test func zshIntegrationRegistersCompletionForEveryCommand() {
        let script = ShellIntegration.zsh()
        for command in ShellIntegration.commands {
            #expect(script.contains("    \(command.name))\n"))
        }
        #expect(script.contains("compdef _plume plume"))
    }

    /// Past the shell name, `init` offers only `--aliases`; an `_arguments`
    /// at the shell position would read `zsh` as its own argument.
    @Test func initCompletesTheShellNameThenAliases() throws {
        let initCommand = try #require(ShellIntegration.commands.first { $0.name == "init" })
        #expect(initCommand.completion.contains("_values 'shell' zsh"))
        #expect(initCommand.completion.contains("--aliases"))
    }

    @Test func wtRoutesItsArgumentsVerbatim() throws {
        #expect(try parse(["wt"]) == .wt([]))
        #expect(try parse(["wt", "co", "-b", "x", "--task"]) == .wt(["co", "-b", "x", "--task"]))
        #expect(try CLICommandLine.parse(["list", "--json"], executableName: "wt") == .wt(["list", "--json"]))
        #expect(try CLICommandLine.parse(["--version"], executableName: "wt") == .wt(["--version"]))
    }

    @Test func zshIntegrationParses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", "-c", ShellIntegration.zsh()]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
