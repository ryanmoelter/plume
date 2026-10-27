import Foundation
import Testing
@testable import Plume

/// `plume init zsh` carries wt's completion and leaves `plume` itself a
/// plain command. `--aliases` adds a bare `wt()`, the only place `wt switch`
/// becomes a `cd`. Ported from the wt half of `test_init.py`.
struct WTInitTests {
    private func parses(_ script: String) throws -> Bool {
        try zsh(["-n", "-c", script]).status == 0
    }

    private func zsh(_ arguments: [String], path: String? = nil) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        if let path { process.environment = ["PATH": path] }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `script` after the integration with `--aliases`, in a shell whose
    /// PATH finds only `bin` and the system.
    private func runWithAliases(_ script: String, bin: URL) throws -> (status: Int32, stdout: String) {
        try zsh(["-f", "-c", ShellIntegration.zsh(aliases: true) + "\n" + script], path: "\(bin.path):/usr/bin:/bin")
    }

    /// A directory holding a fake `plume` that logs its arguments to
    /// `calls` and answers `wt path <name>` with `<target>/<name>`.
    private func fakePlume(exitStatus: Int = 0) throws -> (bin: URL, target: URL, calls: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wt-init-\(UUID().uuidString)")
        let bin = root.appending(path: "bin")
        let target = root.appending(path: "target")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appending(path: "foo"), withIntermediateDirectories: true)
        let calls = root.appending(path: "calls")
        let script = """
            #!/bin/sh
            echo "$*" >> '\(calls.path)'
            if [ "$1 $2" = "wt path" ]; then echo '\(target.path)/'"$3"; fi
            exit \(exitStatus)
            """
        let tool = bin.appending(path: "plume")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (bin, target, calls)
    }

    @Test(arguments: [false, true])
    func plumeStaysAPlainCommand(_ aliases: Bool) throws {
        let script = ShellIntegration.zsh(aliases: aliases)
        #expect(!lines(script).contains("plume() {"))
        let (bin, _, _) = try fakePlume()
        let result = try zsh(["-f", "-c", script + "\nwhence -w plume"], path: "\(bin.path):/usr/bin:/bin")
        #expect(result.stdout == "plume: command\n")
    }

    /// Asks for `wt path`, not `wt switch`: reaching the binary's `switch`
    /// is the error that tells users to load the aliases.
    @Test(arguments: ["switch", "s"])
    func bareWtSwitchCdsToThePathPlumePrints(_ command: String) throws {
        let (bin, target, calls) = try fakePlume()
        let result = try runWithAliases("wt \(command) foo && pwd", bin: bin)
        #expect(result.status == 0)
        #expect(result.stdout == target.appending(path: "foo").path + "\n")
        #expect(try String(contentsOf: calls, encoding: .utf8) == "wt path foo\n")
    }

    @Test func bareWtPassesEverythingElseToPlumeWt() throws {
        let (bin, _, calls) = try fakePlume()
        #expect(try runWithAliases("wt list --json", bin: bin).status == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "wt list --json\n")
    }

    @Test func aFailedPathLeavesTheDirectoryAlone() throws {
        let (bin, _, _) = try fakePlume(exitStatus: 3)
        let result = try runWithAliases("cd /; wt switch foo; code=$?; pwd; exit $code", bin: bin)
        #expect(result.status == 3)
        #expect(result.stdout == "/\n")
    }

    private func lines(_ script: String) -> [String] {
        script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    @Test func wtIsACompletedSubcommand() {
        #expect(ShellIntegration.commands.contains { $0.name == "wt" })
        #expect(ShellIntegration.zsh().contains("    wt)\n"))
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
