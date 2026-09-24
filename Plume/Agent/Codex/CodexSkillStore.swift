import Foundation
import Observation

nonisolated struct CodexSkill: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let description: String
    var id: String { path }
    var command: SlashCommand { SlashCommand(name: name, description: description, argumentHint: "") }

    static func decode(_ response: JSONValue, directory: String) -> [Self] {
        var names: Set<String> = []
        return (response["data"]?.arrayValue ?? [])
            .filter { $0["cwd"]?.stringValue == directory }
            .flatMap { $0["skills"]?.arrayValue ?? [] }
            .compactMap { value in
                guard value["enabled"]?.boolValue != false,
                      let name = value["name"]?.stringValue, !name.isEmpty,
                      let path = value["path"]?.stringValue, path.hasPrefix("/"),
                      names.insert(name).inserted else { return nil }
                return Self(name: name, path: path, description: value["description"]?.stringValue ?? "")
            }.sorted { $0.name < $1.name }
    }

    /// Attach only explicitly named, discovered skills. Arbitrary draft text
    /// cannot supply a filesystem path to the protocol.
    static func input(text: String, skills: [Self]) -> [JSONValue] {
        let tokens = Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        return [.object(["type": .string("text"), "text": .string(text)])] + skills
            .filter { tokens.contains("$" + $0.name) }
            .map { .object(["type": .string("skill"), "name": .string($0.name), "path": .string($0.path)]) }
    }
}

/// Read-only discovery also works before the first conversation is created.
@MainActor @Observable
final class CodexSkillStore {
    static let shared = CodexSkillStore()
    private var catalogs: [String: [CodexSkill]] = [:]
    private(set) var errors: [String: String] = [:]

    func skills(in directory: String?) -> [CodexSkill] {
        guard let directory else { return [] }
        return catalogs[directory] ?? []
    }

    func replace(_ response: JSONValue, directory: String) {
        catalogs[directory] = CodexSkill.decode(response, directory: directory)
        errors.removeValue(forKey: directory)
    }

    func refresh(directory: String) async {
        let client = CodexAppServerClient()
        await withTaskCancellationHandler {
            await load(client: client, directory: directory)
        } onCancel: {
            Task { @MainActor in client.stop() }
        }
    }

    private func load(client: CodexAppServerClient, directory: String) async {
        defer { client.stop() }
        do {
            try client.start(workingDirectory: directory, environment: [:])
            _ = try await client.send("initialize", .object([
                "clientInfo": .object(["name": .string("plume-skills"), "version": .string("1")]),
                "capabilities": CodexSession.initializeCapabilities
            ]))
            client.notify("initialized")
            let result = try await client.send("skills/list", .object([
                "cwds": .array([.string(directory)]), "forceReload": .bool(true)
            ]))
            guard !Task.isCancelled else { return }
            replace(result, directory: directory)
        } catch {
            guard !Task.isCancelled else { return }
            errors[directory] = error.localizedDescription
        }
    }
}
