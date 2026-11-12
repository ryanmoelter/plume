import Foundation

// Shared/ is compiled into both the app and the `plume` tool, whose default
// actor isolations differ, so every declaration here is explicitly
// nonisolated. `docs/cli.md` is the wire reference.

/// One request line from `plume` to the running app.
nonisolated enum CLIRequest: Equatable, Sendable {
    case ping
    case notify(Notify)
    case newTab(NewTab)
    case newTask(NewTask)
    case openSettings(OpenSettings)
    case showDevice(ShowDevice)
    case reserveDevice(ReserveDevice)
    case releaseDevice(ReleaseDevice)
    case extendDevice(ExtendDevice)
    case linkIssue(LinkIssue)
    case unlinkIssue(LinkIssue)

    struct Notify: Codable, Equatable, Sendable {
        var tabID: UUID
        var title: String
        var body: String
    }

    /// Names its task outright, or through a tab in it — the calling tab,
    /// whose task can change when the tab is moved. `taskID` wins.
    struct NewTab: Codable, Equatable, Sendable {
        var taskID: UUID?
        var tabID: UUID?
        var directory: String?
        var select: Bool
    }

    /// A task for the worktree at `worktreePath`, beside the caller's task
    /// (`taskID`, else the task holding `tabID`). The app reads the
    /// repository and branch from the worktree itself.
    struct NewTask: Codable, Equatable, Sendable {
        var worktreePath: String
        var taskID: UUID?
        var tabID: UUID?
        var select: Bool
        /// Whether `wt` created the worktree, and its branch. The task owns
        /// only what was created; an older client sends neither, so it owns
        /// nothing.
        var createdWorktree: Bool? = nil
        var createdBranch: Bool? = nil
    }

    /// Shows the Settings window, on `section` when given (`projects`, say).
    struct OpenSettings: Codable, Equatable, Sendable {
        var section: String?
    }

    /// Shows a leased device in a device tab of the task holding `tabID`, the
    /// lease's owner. An emulator is named by `avdID`, a physical device by
    /// `serial` and a remote one by `reservationID`.
    struct ShowDevice: Codable, Equatable, Sendable {
        var tabID: UUID
        var kind: DeviceKind
        var serial: String?
        var avdID: String?
        var reservationID: String?
        var displayName: String?
    }

    /// Reserves a remote device for `tabID` in a device tab of its task. The app answers once the
    /// claim is recorded, not once the device connects; the claimant then waits on the registry.
    /// `model` and `projectID` default to what the device picker last used. With no `model`,
    /// `form` picks one of that form from the catalog.
    struct ReserveDevice: Codable, Equatable, Sendable {
        var tabID: UUID
        var model: String?
        var form: DeviceForm?
        var projectID: String?
        var ttl: TimeInterval?
        var worktree: String?
        var branch: String?
    }

    /// Drops the lease keyed `key`, which this app must own, and ends its reservation.
    struct ReleaseDevice: Codable, Equatable, Sendable {
        var key: String
    }

    /// Extends the reservation behind the remote lease keyed `key`, which this app must own, so it
    /// lasts at least `ttl` seconds from now. The app answers once Device Streaming has.
    struct ExtendDevice: Codable, Equatable, Sendable {
        var key: String
        var ttl: TimeInterval
    }

    /// Links `issue`, an identifier or issue URL, to a task named as `NewTab` names one, or
    /// unlinks it. The app validates `issue`.
    struct LinkIssue: Codable, Equatable, Sendable {
        var issue: String
        var taskID: UUID?
        var tabID: UUID?
    }
}

nonisolated extension CLIRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case command, params
    }

    private enum Command: String, Codable {
        case ping, notify
        case newTab = "tab.new"
        case newTask = "task.new"
        case openSettings = "settings.open"
        case showDevice = "devices.show"
        case reserveDevice = "devices.reserve"
        case releaseDevice = "devices.release"
        case extendDevice = "devices.extend"
        case linkIssue = "issue.link"
        case unlinkIssue = "issue.unlink"
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
        case .newTask: self = .newTask(try container.decode(NewTask.self, forKey: .params))
        case .openSettings: self = .openSettings(try container.decode(OpenSettings.self, forKey: .params))
        case .showDevice: self = .showDevice(try container.decode(ShowDevice.self, forKey: .params))
        case .reserveDevice: self = .reserveDevice(try container.decode(ReserveDevice.self, forKey: .params))
        case .releaseDevice: self = .releaseDevice(try container.decode(ReleaseDevice.self, forKey: .params))
        case .extendDevice: self = .extendDevice(try container.decode(ExtendDevice.self, forKey: .params))
        case .linkIssue: self = .linkIssue(try container.decode(LinkIssue.self, forKey: .params))
        case .unlinkIssue: self = .unlinkIssue(try container.decode(LinkIssue.self, forKey: .params))
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
        case .newTask(let params):
            try container.encode(Command.newTask, forKey: .command)
            try container.encode(params, forKey: .params)
        case .openSettings(let params):
            try container.encode(Command.openSettings, forKey: .command)
            try container.encode(params, forKey: .params)
        case .showDevice(let params):
            try container.encode(Command.showDevice, forKey: .command)
            try container.encode(params, forKey: .params)
        case .reserveDevice(let params):
            try container.encode(Command.reserveDevice, forKey: .command)
            try container.encode(params, forKey: .params)
        case .releaseDevice(let params):
            try container.encode(Command.releaseDevice, forKey: .command)
            try container.encode(params, forKey: .params)
        case .extendDevice(let params):
            try container.encode(Command.extendDevice, forKey: .command)
            try container.encode(params, forKey: .params)
        case .linkIssue(let params):
            try container.encode(Command.linkIssue, forKey: .command)
            try container.encode(params, forKey: .params)
        case .unlinkIssue(let params):
            try container.encode(Command.unlinkIssue, forKey: .command)
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
    var taskID: UUID?
    var version: String?
    /// Whether the request made the tab it names, as `devices.show` reports.
    var created: Bool?
    /// The pending claim `devices.reserve` recorded, which names the lease once it connects.
    var claimID: UUID?
    /// The Linear identifier `issue.link` or `issue.unlink` acted on, uppercased.
    var issue: String?

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

        /// Bytes held that aren't yet part of a complete line handed back.
        var count: Int { pending.count }

        mutating func append(_ data: Data) {
            pending.append(data)
        }

        mutating func nextLine() -> Data? {
            guard let newline = pending.firstIndex(of: 0x0A) else { return nil }
            let line = Data(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            return line
        }

        /// What's left once the peer has finished: a final line it sent
        /// without a trailing newline.
        mutating func takeRemainder() -> Data? {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return pending
        }
    }
}
