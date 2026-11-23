import Foundation

/// Models Claude Code offers for the configuration in a working directory.
nonisolated enum ClaudeModelCatalog {
    static func models(in payload: [String: JSONValue]) -> [AgentModel]? {
        var ids: Set<String> = []
        return payload["models"]?.arrayValue?.compactMap { value in
            guard let id = value["value"]?.stringValue, !id.isEmpty, id != "default",
                  (try? ModelEffortCommand.sanitizedToken(id)) != nil,
                  ids.insert(id).inserted else { return nil }

            let model = AgentModel(unrecognizedID: value["resolvedModel"]?.stringValue ?? id)
            let displayName = value["displayName"]?.stringValue
            let family = model.label.split(separator: " ").first.map(String.init)
            let label = displayName != family ? displayName ?? model.label : model.label
            return AgentModel(id: id, label: label)
        }
    }

    @concurrent
    static func discover(in directory: String) async -> [AgentModel]? {
        guard ClaudeTrustStore.isTrusted(directory),
              let request = StreamJSONEncoder.initialize(requestID: "models") else { return nil }

        let (results, continuation) = AsyncStream<[AgentModel]?>.makeStream()
        let process = AgentProcess(
            label: "claude model catalog",
            onLine: { line in
                guard case .controlResponse(let response) = StreamJSONDecoder.decode(line: line),
                      response.requestID == "models" else { return }
                continuation.yield(response.isError ? nil : models(in: response.payload))
                continuation.finish()
            },
            onExit: { _, _ in continuation.finish() }
        )
        do {
            try process.start(
                arguments: ClaudeUsageRequest.arguments,
                workingDirectory: directory,
                environment: LoginShellCommand.plumeEnvironment,
                removingEnvironment: ClaudeUsageRequest.droppedEnvironmentKeys
            )
        } catch {
            return nil
        }

        defer { process.terminate() }
        guard process.send(line: request) else { return nil }
        let timeout = Task {
            try await Task.sleep(for: .seconds(3))
            continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? nil
    }
}

@MainActor
@Observable
final class ClaudeModelCatalogStore {
    static let shared = ClaudeModelCatalogStore()
    private var catalogs: [String: [AgentModel]] = [:]
    @ObservationIgnored private var pending: [String: Task<[AgentModel]?, Never>] = [:]

    func models(in directory: String?) -> [AgentModel]? {
        directory.flatMap { catalogs[$0] }
    }

    func refresh(in directory: String) async {
        if let task = pending[directory] {
            catalogs[directory] = await task.value
            return
        }
        let task = Task { await ClaudeModelCatalog.discover(in: directory) }
        pending[directory] = task
        catalogs[directory] = await task.value
        pending[directory] = nil
    }
}
