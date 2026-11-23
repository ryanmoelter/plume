import Foundation
import Testing
@testable import Plume

struct CodexDetachedProcessMonitorTests {
    @Test func reusedProcessGroupsDoNotInheritAnOldJobIdentity() {
        typealias Identity = CodexDetachedProcessMonitor.ProcessIdentity
        let old = Identity(pid: 100, group: 100, seconds: 1, microseconds: 0, parent: 1)
        let worker = Identity(pid: 101, group: 100, seconds: 2, microseconds: 0, parent: 1)
        let anchor = CodexDetachedProcess(id: old.id, startedAt: old.startedAt)
        let continuing = CodexDetachedProcessMonitor.groupedProcesses([worker], previous: [old, worker], anchors: [100: anchor])
        #expect(continuing[100] == anchor)
        let reused = Identity(pid: 100, group: 100, seconds: 3, microseconds: 0, parent: 1)
        let replacement = CodexDetachedProcessMonitor.groupedProcesses([reused], previous: [old, worker], anchors: [100: anchor])
        #expect(replacement[100]?.id == reused.id)
        #expect(replacement[100]?.startedAt == reused.startedAt)
    }

    @Test func incompatibleEnvironmentPoliciesAreNotReplaced() {
        #expect(CodexDetachedProcessMonitor.isCompatible(.object([:]), environment: ["SHELL": "/bin/zsh"]))
        #expect(!CodexDetachedProcessMonitor.isCompatible(.object([:]), environment: ["SHELL": "/bin/bash"]))
        for policy in [
            #"{"inherit":"none"}"#,
            #"{"exclude":["ZDOTDIR"]}"#,
            #"{"include_only":["PATH"]}"#,
            #"{"filters":{"PATH":"include"}}"#,
            #"{"experimental_use_profile":true}"#,
            #"{"set":{"SHELL":"/bin/bash"}}"#
        ] {
            let value = try! JSONDecoder().decode(JSONValue.self, from: Data(policy.utf8))
            #expect(!CodexDetachedProcessMonitor.isCompatible(.object(["shell_environment_policy": value]), environment: ["SHELL": "/bin/zsh"]))
        }
    }

    @Test func capturePreservesTheDifferenceBetweenUnsetAndEmptyZDOTDIR() async throws {
        let unset = try await run(CodexCommand.capturingShellEnvironment([
            "/bin/sh", "-c", "printf '%s|%s' \"$PLUME_CODEX_ZDOTDIR_SET\" \"${PLUME_CODEX_ORIGINAL_ZDOTDIR-unset}\""
        ]), environment: [:])
        #expect(unset == "0|unset")
        let empty = try await run(CodexCommand.capturingShellEnvironment([
            "/bin/sh", "-c", "printf '%s|%s' \"$PLUME_CODEX_ZDOTDIR_SET\" \"${PLUME_CODEX_ORIGINAL_ZDOTDIR-unset}\""
        ]), environment: ["ZDOTDIR": ""])
        #expect(empty == "1|")
    }

    @Test func shimPreservesConfiguredProfilesAndTrulyUnsetZDOTDIR() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try "setopt nounset\nexport PLUME_TEST_ENV=env\n".write(to: original.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export PLUME_TEST_PROFILE=profile\n".write(to: original.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let lease = try CodexDetachedProcessMonitor.Lease.create(configuration: .object([
            "shell_environment_policy": .object(["set": .object(["ZDOTDIR": .string(original.path)])])
        ]), baseDirectory: root)
        defer { lease.remove() }
        let configured = try await run(["/bin/zsh", "-lc", "printf '%s|%s|%s' \"$PLUME_TEST_ENV\" \"$PLUME_TEST_PROFILE\" \"$ZDOTDIR\""],
                                       environment: environment(lease, home: root))
        #expect(configured == "env|profile|\(original.path)")

        let unsetLease = try CodexDetachedProcessMonitor.Lease.create(configuration: .object([:]), baseDirectory: root)
        defer { unsetLease.remove() }
        try "export PLUME_TEST_SET=${ZDOTDIR+x}\n".write(to: root.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let unset = try await run(["/bin/zsh", "-lc", "printf '%s|%s' \"$PLUME_TEST_SET\" \"${ZDOTDIR+x}\""],
                                  environment: environment(unsetLease, home: root))
        #expect(unset == "|")
    }

    @Test func orphanedMarkedWorkRetiresWhenItsProcessExits() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try CodexDetachedProcessMonitor.Lease.create(configuration: .object([:]), baseDirectory: root)
        defer { lease.remove() }
        let release = root.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let process = AgentProcess(label: "marker-test", onLine: { _ in }, onExit: { _, _ in })
        let worker = #"for ((i=0; i<300; i++)); do [[ -e "$1" || ! -d "$2" ]] && exit; /bin/sleep 0.1; done"#
        try process.start(
            arguments: ["/bin/zsh", "-c", "( " + worker + " ) >/dev/null 2>&1 &", "marker-test", release.path, root.path],
            workingDirectory: root.path, environment: environment(lease, home: root)
        )
        await process.waitUntilExited()
        let found = CodexDetachedProcessMonitor.scan(marker: lease.marker, retaining: [])
        #expect(!found.isEmpty)
        #expect(found.contains { $0.parent == 1 })
        try Data().write(to: release)
        let deadline = ContinuousClock.now + .seconds(5)
        var remaining = found
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            remaining = CodexDetachedProcessMonitor.scan(marker: lease.marker, retaining: remaining)
        }
        #expect(remaining.isEmpty)
    }

    private func environment(_ lease: CodexDetachedProcessMonitor.Lease, home: URL) -> [String: String] {
        var result = ["HOME": home.path, "PATH": "/usr/bin:/bin", "CODEX_THREAD_ID": "test-thread", "PLUME_CODEX_ZDOTDIR_SET": "0"]
        for (key, value) in lease.overrides {
            result[String(key.dropFirst("shell_environment_policy.set.".count))] = value.stringValue
        }
        return result
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plume-marker-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func run(_ arguments: [String], environment: [String: String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: arguments[0])
            process.arguments = Array(arguments.dropFirst())
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
