import Foundation
import Testing
@testable import Plume

/// `plume init zsh` carries wt's completion and leaves `plume` itself a
/// plain command. `--aliases` defines a bare `wt()`, the only place
/// `wt switch` becomes a `cd`, and a bare `stack` alias that completes as
/// `plume stack`; `--alias wt` defines only the first. Ported from the wt
/// half of `test_init.py`.
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
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errors.fileHandleForReading.readabilityHandler = nil
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// `script` after the integration with `--aliases`, in a shell whose
    /// PATH finds only `bin` and the system.
    private func runWithAliases(_ script: String, bin: URL) throws -> (status: Int32, stdout: String) {
        try zsh(["-f", "-c", ShellIntegration.zsh(aliasNames: ["wt"]) + "\n" + script], path: "\(bin.path):/usr/bin:/bin")
    }

    /// A directory holding a fake `plume` that logs its arguments to
    /// `calls` and answers `wt path <name>` with `<target>/<name>`.
    private func fakePlume(exitStatus: Int = 0) throws -> (bin: URL, target: URL, calls: URL, root: URL) {
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
        return (bin, target, calls, root)
    }

    @Test(arguments: [false, true])
    func plumeStaysAPlainCommand(_ aliases: Bool) throws {
        let script = ShellIntegration.zsh(aliasNames: aliases ? ["wt"] : [])
        #expect(!lines(script).contains("plume() {"))
        let (bin, _, _, root) = try fakePlume()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try zsh(["-f", "-c", script + "\nwhence -w plume"], path: "\(bin.path):/usr/bin:/bin")
        #expect(result.stdout == "plume: command\n")
    }

    /// Asks for `wt path`, not `wt switch`: reaching the binary's `switch`
    /// is the error that tells users to load the aliases.
    @Test(arguments: ["switch", "s"])
    func bareWtSwitchCdsToThePathPlumePrints(_ command: String) throws {
        let (bin, target, calls, root) = try fakePlume()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try runWithAliases("wt \(command) foo && pwd", bin: bin)
        #expect(result.status == 0)
        #expect(result.stdout == target.appending(path: "foo").path + "\n")
        #expect(try String(contentsOf: calls, encoding: .utf8) == "wt path foo\n")
    }

    @Test func bareWtPassesEverythingElseToPlumeWt() throws {
        let (bin, _, calls, root) = try fakePlume()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try runWithAliases("wt list --json", bin: bin).status == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "wt list --json\n")
    }

    @Test func aFailedPathLeavesTheDirectoryAlone() throws {
        let (bin, _, _, root) = try fakePlume(exitStatus: 3)
        defer { try? FileManager.default.removeItem(at: root) }
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

    private func script(for flags: [String]) throws -> [String] {
        let invocation = try CLICommandLine.parse(["init", "zsh"] + flags, executableName: "plume")
        guard case .shellInit(let names) = invocation else { Issue.record("not shellInit"); return [] }
        return lines(ShellIntegration.zsh(aliasNames: names))
    }

    @Test func aliasesAddABareWtFunctionAndAStackAlias() throws {
        let script = try script(for: ["--aliases"])
        #expect(script.contains("wt() {"))
        #expect(script.contains { $0.hasPrefix("compdef ") && $0.hasSuffix(" wt") })
        #expect(script.contains("alias stack='plume stack'"))
        #expect(!script.contains("stack() {"))
        #expect(!script.contains { $0.hasPrefix("compdef ") && $0.hasSuffix(" stack") })
    }

    @Test func aliasWtAddsOnlyABareWtFunction() throws {
        let script = try script(for: ["--alias", "wt"])
        #expect(script.contains("wt() {"))
        #expect(!script.contains { $0.hasPrefix("alias stack=") })
    }

    /// zsh completes an alias by expanding it unless `complete_aliases` is
    /// set, so with no compdef of its own `stack <Tab>` completes as
    /// `plume stack`.
    @Test func anEvaluatedStackAliasCompletesAsPlume() throws {
        let probe = """
            autoload -Uz compinit && compinit -u -D
            \(ShellIntegration.zsh(aliasNames: ["wt", "stack"]))
            print -r -- "alias=${aliases[stack]}"
            print -r -- "function=${+functions[stack]}"
            print -r -- "stack=${_comps[stack]-none} plume=${_comps[plume]} wt=${_comps[wt]}"
            [[ -o complete_aliases ]] && print complete_aliases=on || print complete_aliases=off
            """
        let result = try zsh(["-f", "-c", probe], path: "/usr/bin:/bin")
        #expect(result.status == 0)
        #expect(result.stdout == """
            alias=plume stack
            function=0
            stack=none plume=_plume wt=_plume_wt
            complete_aliases=off

            """)
    }

    @Test func bareStackRunsPlumeStack() throws {
        let (bin, _, calls, root) = try fakePlume()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = ShellIntegration.zsh(aliasNames: ["stack"]) + "\neval 'stack list --all'"
        #expect(try zsh(["-f", "-c", script], path: "\(bin.path):/usr/bin:/bin").status == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "stack list --all\n")
    }

    /// The script is eval'd at shell startup, so a quoting slip would break
    /// every new shell.
    @Test(arguments: [[], ["wt"], ["stack"], ["wt", "stack"]])
    func theScriptParses(_ names: [String]) throws {
        #expect(try parses(ShellIntegration.zsh(aliasNames: names)))
    }

    /// `init` belongs to `plume`, which needs no repository.
    @Test func wtInitPointsAtPlumeInit() {
        let console = BufferConsole()
        let status = WT.main(["init", "zsh"], environment: [:], console: console, version: "1.0")
        #expect(status != 0)
        #expect(console.stderr.contains("plume init zsh --aliases"))
    }

    @Test func versionRunsOutsideARepository() {
        let console = BufferConsole()
        #expect(WT.main(["--version"], environment: [:], console: console, version: "1.0") == 0)
        #expect(console.stdout.hasPrefix("wt "))
    }
}
