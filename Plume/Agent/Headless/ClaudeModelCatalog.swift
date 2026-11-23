import Foundation

/// Models Claude Code offers for the configuration in a working directory.
nonisolated struct ClaudeModelCatalog: Sendable {
    let models: [AgentModel]
    let defaultModel: AgentModel?

    init?(payload: [String: JSONValue]) {
        guard let entries = payload["models"]?.arrayValue else { return nil }
        let defaultID = entries.first { $0["value"]?.stringValue == "default" }?["resolvedModel"]?.stringValue
        defaultModel = defaultID.flatMap { AgentModel.recognizing($0) }
        var ids: Set<String> = []
        models = entries.compactMap { value in
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
    static func discover(in directory: String) async -> ClaudeModelCatalog? {
        guard ClaudeTrustStore.isTrusted(directory),
              let request = StreamJSONEncoder.initialize(requestID: "models") else { return nil }

        let (results, continuation) = AsyncStream<ClaudeModelCatalog?>.makeStream()
        let process = AgentProcess(
            label: "claude model catalog",
            onLine: { line in
                guard case .controlResponse(let response) = StreamJSONDecoder.decode(line: line),
                      response.requestID == "models" else { return }
                continuation.yield(response.isError ? nil : ClaudeModelCatalog(payload: response.payload))
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
    private var catalogs: [String: ClaudeModelCatalog] = [:]
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]

    func catalog(in directory: String?) -> ClaudeModelCatalog? {
        directory.flatMap { catalogs[$0] }
    }

    func refresh(in directory: String) async {
        if let task = pending[directory] {
            await task.value
            return
        }
        let task = Task {
            catalogs[directory] = await ClaudeModelCatalog.discover(in: directory)
            pending[directory] = nil
        }
        pending[directory] = task
        await task.value
    }
}
