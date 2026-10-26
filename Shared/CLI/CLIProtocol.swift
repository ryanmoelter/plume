import Foundation

// Shared/ is compiled into both the app and the `plume` tool, whose default
// actor isolations differ, so every declaration here is explicitly
// nonisolated. `docs/cli.md` is the wire reference.

/// One request line from `plume` to the running app.
nonisolated enum CLIRequest: Equatable, Sendable {
    case ping
    case notify(Notify)
    case newTab(NewTab)

    struct Notify: Codable, Equatable, Sendable {
        var tabID: UUID
        var title: String
        var body: String
    }

    struct NewTab: Codable, Equatable, Sendable {
        var taskID: UUID
        var directory: String?
        var select: Bool
    }
}

nonisolated extension CLIRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, params
    }

    private enum Command: String, Codable {
        case ping, notify
        case newTab = "tab.new"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .command)
        guard let command = Command(rawValue: name) else {
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container, debugDescription: "unknown command \(name)"
            )
        }
        switch command {
        case .ping: self = .ping
        case .notify: self = .notify(try container.decode(Notify.self, forKey: .params))
        case .newTab: self = .newTab(try container.decode(NewTab.self, forKey: .params))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping:
            try container.encode(Command.ping, forKey: .command)
        case .notify(let params):
            try container.encode(Command.notify, forKey: .command)
            try container.encode(params, forKey: .params)
        case .newTab(let params):
            try container.encode(Command.newTab, forKey: .command)
            try container.encode(params, forKey: .params)
        }
    }
}

/// The app's one-line answer. Fields a command has no use for stay nil and
/// are left out of the JSON.
nonisolated struct CLIResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var error: String?
    var tabID: UUID?
    var version: String?

    static let success = CLIResponse(ok: true)

    static func failure(_ message: String) -> CLIResponse {
        CLIResponse(ok: false, error: message)
    }
}

/// Newline-delimited JSON: one compact object per line.
nonisolated enum CLILineCodec {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }

    /// Accumulates reads and hands back each complete line, without its
    /// terminator.
    struct Buffer {
        private var pending = Data()

        mutating func append(_ data: Data) {
            pending.append(data)
        }

        mutating func nextLine() -> Data? {
            guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
            let line = Data(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            return line
        }
    }
}
