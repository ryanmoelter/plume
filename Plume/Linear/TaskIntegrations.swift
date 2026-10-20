import Foundation

/// Per-task integration state, stored as one JSON blob so a new integration
/// adds a field rather than a schema migration.
nonisolated struct TaskIntegrations: Codable, Equatable {
    var version = 1
    var linear: LinearTaskLinks?

    init(version: Int = 1, linear: LinearTaskLinks? = nil) {
        self.version = version
        self.linear = linear
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        linear = try? container.decodeIfPresent(LinearTaskLinks.self, forKey: .linear)
    }

    static func decode(_ data: Data?) -> TaskIntegrations {
        guard let data, let value = try? JSONDecoder().decode(TaskIntegrations.self, from: data) else {
            return TaskIntegrations()
        }
        return value
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

nonisolated struct LinearTaskLinks: Codable, Equatable {
    var manual: [LinearIssueRef] = []
    var promoted: [LinearIssueRef] = []
    var agentStarted: [LinearIssueRef] = []
    var dismissed: [String] = []

    init(
        manual: [LinearIssueRef] = [],
        promoted: [LinearIssueRef] = [],
        agentStarted: [LinearIssueRef] = [],
        dismissed: [String] = []
    ) {
        self.manual = manual
        self.promoted = promoted
        self.agentStarted = agentStarted
        self.dismissed = dismissed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manual = (try? container.decodeIfPresent([LinearIssueRef].self, forKey: .manual)) ?? []
        promoted = (try? container.decodeIfPresent([LinearIssueRef].self, forKey: .promoted)) ?? []
        agentStarted = (try? container.decodeIfPresent([LinearIssueRef].self, forKey: .agentStarted)) ?? []
        dismissed = (try? container.decodeIfPresent([String].self, forKey: .dismissed)) ?? []
    }

    var isEmpty: Bool {
        manual.isEmpty && promoted.isEmpty && agentStarted.isEmpty && dismissed.isEmpty
    }

    mutating func link(_ ref: LinearIssueRef) {
        undismiss(ref.identifier)
        Self.add(ref, to: &manual)
    }

    mutating func promote(_ ref: LinearIssueRef) {
        Self.add(ref, to: &promoted)
    }

    /// Returns whether anything changed. A dismissed issue stays dismissed.
    @discardableResult
    mutating func recordAgentStarted(_ ref: LinearIssueRef) -> Bool {
        guard !dismissed.contains(ref.identifier),
              !agentStarted.contains(where: { $0.identifier == ref.identifier })
        else { return false }
        agentStarted.append(ref)
        return true
    }

    mutating func unlink(_ identifier: String) {
        let id = identifier.uppercased()
        manual.removeAll { $0.identifier == id }
        promoted.removeAll { $0.identifier == id }
        agentStarted.removeAll { $0.identifier == id }
        if !dismissed.contains(id) { dismissed.append(id) }
    }

    mutating func undismiss(_ identifier: String) {
        let id = identifier.uppercased()
        dismissed.removeAll { $0 == id }
    }

    private static func add(_ ref: LinearIssueRef, to list: inout [LinearIssueRef]) {
        if let index = list.firstIndex(where: { $0.identifier == ref.identifier }) {
            if list[index].orgID == nil { list[index].orgID = ref.orgID }
        } else {
            list.append(ref)
        }
    }
}
