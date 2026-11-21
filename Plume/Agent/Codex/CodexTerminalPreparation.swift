import Foundation

@MainActor
enum CodexTerminalPreparation {
    enum Failure: Error {
        case configurationUnavailable
        case invalidEnvironmentOverride
    }

    static func configuration(directory: String?, environment: [String: String], client injected: CodexAppServerClient? = nil) async throws -> JSONValue {
        let client = injected ?? CodexAppServerClient()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            client.stop()
        }
        defer { timeout.cancel(); client.stop() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try client.start(workingDirectory: directory, environment: environment)
            _ = try await client.send("initialize", .object([
                "clientInfo": .object(["name": .string("plume_terminal_configuration"), "version": .string("1")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try Task.checkCancellation()
            client.notify("initialized")
            var params: [String: JSONValue] = ["includeLayers": .bool(false)]
            if let directory { params["cwd"] = .string(directory) }
            let response = try await client.send("config/read", .object(params))
            try Task.checkCancellation()
            guard let config = response["config"], config.objectValue != nil else { throw Failure.configurationUnavailable }
            return config
        } onCancel: {
            Task { @MainActor in client.stop() }
        }
    }

    static func serverArguments(socketPath: String, overrides: [String: JSONValue]) throws -> [String] {
        var arguments = ["codex", "app-server", "--listen", "unix://" + socketPath]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for key in overrides.keys.sorted() {
            guard key.hasPrefix("shell_environment_policy.set."), let value = overrides[key],
                  value.stringValue != nil else { throw Failure.invalidEnvironmentOverride }
            let literal = String(decoding: try encoder.encode(value), as: UTF8.self)
            arguments += ["-c", key + "=" + literal]
        }
        return CodexCommand.capturingShellEnvironment(arguments)
    }
}
