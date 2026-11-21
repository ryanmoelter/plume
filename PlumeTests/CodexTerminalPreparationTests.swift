import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexTerminalPreparationTests {
    @MainActor
    private final class Harness {
        var client: CodexAppServerClient!
        var requests: [(String, JSONValue)] = []
        var config: JSONValue

        init(config: JSONValue) {
            self.config = config
            client = CodexAppServerClient { [weak self] line in
                guard let self, let data = line.data(using: .utf8),
                      let request = try? JSONDecoder().decode(JSONValue.self, from: data),
                      let method = request["method"]?.stringValue else { return false }
                requests.append((method, request["params"] ?? .null))
                guard let id = request["id"] else { return true }
                let response: JSONValue = .object(["id": id, "result": method == "config/read" ? .object(["config": config]) : .object([:])])
                let text = String(decoding: try! JSONEncoder().encode(response), as: UTF8.self)
                Task { @MainActor in self.client.receive(text) }
                return true
            }
        }
    }

    @Test func effectiveConfigurationIsReadForTheTerminalDirectoryWithoutChangingIt() async throws {
        let config: JSONValue = .object(["shell_environment_policy": .object(["set": .object([
            "ZDOTDIR": .string("/custom/zsh"), "KEEP": .string("retained")
        ])])])
        let harness = Harness(config: config)
        let result = try await CodexTerminalPreparation.configuration(directory: "/project", environment: [:], client: harness.client)
        #expect(result == config)
        #expect(harness.requests.map(\.0) == ["initialize", "initialized", "config/read"])
        #expect(harness.requests.last?.1 == .object(["cwd": .string("/project"), "includeLayers": .bool(false)]))
    }

    @Test func unavailableOptionalConfigurationFallsBackWithoutShellOverrides() async throws {
        let prepared = try await CodexTerminalMonitor.prepareWithConfiguration(tabID: UUID()) {
            throw CodexAppServerClient.Failure.notRunning
        }
        #expect(prepared.overrides.isEmpty)
        #expect(prepared.detached == nil)
    }

    @Test func serverOverridesUseLiteralArgumentsWithoutPuttingTheMarkerOnTheTUI() throws {
        let arguments = try CodexTerminalPreparation.serverArguments(socketPath: "/private/tmp/test/s", overrides: [
            "shell_environment_policy.set.ZDOTDIR": .string("/tmp/a folder/\"quoted\""),
            "shell_environment_policy.set.KEEP": .string("retained")
        ])
        #expect(arguments.suffix(8) == ["codex", "app-server", "--listen", "unix:///private/tmp/test/s", "-c", "shell_environment_policy.set.KEEP=\"retained\"", "-c", "shell_environment_policy.set.ZDOTDIR=\"/tmp/a folder/\\\"quoted\\\"\""])
        #expect(throws: CodexTerminalPreparation.Failure.self) {
            try CodexTerminalPreparation.serverArguments(socketPath: "/tmp/s", overrides: ["unrelated": .string("no")])
        }
    }

    @Test func pendingLaunchIsReservedAndCannotStartAfterTabCloses() async {
        var began: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<CodexTerminalMonitor.Preparation, Never>?
        var preparations = 0
        let monitor = CodexTerminalMonitor { _, _, _ in
            preparations += 1
            return await withCheckedContinuation { continuation in
                release = continuation
                began?.resume()
            }
        }
        let tab = UUID()
        var launch: CodexTerminalMonitor.Launch!
        await withCheckedContinuation { continuation in
            began = continuation
            launch = monitor.start(tabID: tab, taskID: UUID(), directory: "/project", resumeThreadID: "thread") { _ in }
        }
        let duplicate = monitor.start(tabID: tab, taskID: UUID(), directory: "/project") { _ in }
        #expect(duplicate.generation == launch.generation)
        #expect(preparations == 1)
        let destination = UUID()
        monitor.reparent(tabID: tab, taskID: destination)
        #expect(monitor.taskID(forTab: tab) == destination)
        #expect(monitor.owns(threadID: "thread", excludingTabID: UUID()))
        monitor.stop(tabID: tab)
        release?.resume(returning: .init(overrides: [:], detached: nil))
        do {
            _ = try await launch.task.value
            Issue.record("A closed tab must not start a private server")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(monitor.taskID(forTab: tab) == nil)
        #expect(!monitor.isCurrentLaunch(tabID: tab, generation: launch.generation))
        #expect(!monitor.owns(threadID: "thread", excludingTabID: UUID()))
    }
}
