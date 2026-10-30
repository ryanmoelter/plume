import Darwin
import Foundation

nonisolated enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case emulator
    case physical
    case remote
}

/// Who holds a lease. A tab is named together with the socket of the app that owns it, so a debug
/// build and the installed app never mistake each other's tabs for their own.
nonisolated enum DeviceLeaseOwner: Hashable, Sendable, Codable, CustomStringConvertible {
    case tab(id: UUID, app: String)
    case label(String)

    private enum CodingKeys: String, CodingKey {
        case tab, app, label
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .tab) {
            self = .tab(id: id, app: try container.decode(String.self, forKey: .app))
        } else {
            self = .label(try container.decode(String.self, forKey: .label))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let id, let app):
            try container.encode(id, forKey: .tab)
            try container.encode(app, forKey: .app)
        case .label(let label):
            try container.encode(label, forKey: .label)
        }
    }

    var description: String {
        switch self {
        case .tab(let id, _): "Plume tab \(id.uuidString)"
        case .label(let label): label
        }
    }

    var tabID: UUID? {
        if case .tab(let id, _) = self { id } else { nil }
    }

    /// The socket of the app whose tab owns the lease.
    var app: String? {
        if case .tab(_, let app) = self { app } else { nil }
    }
}

nonisolated struct DeviceLease: Codable, Equatable, Sendable {
    struct Remote: Codable, Equatable, Sendable {
        var reservationID: String
        var projectID: String
        var claimID: UUID?
    }

    struct Installed: Codable, Equatable, Sendable {
        var branch: String
        var worktree: String?
        var at: Date
    }

    var kind: DeviceKind
    var serial: String?
    var avd: String?
    var form: DeviceForm?
    var model: String?
    var owner: DeviceLeaseOwner
    var worktree: String?
    var branch: String?
    var claimedAt: Date
    var expiresAt: Date
    var deviceTabID: UUID?
    var deviceTabCreatedByClaim: Bool
    var remote: Remote?
    var installed: Installed?

    init(
        kind: DeviceKind,
        serial: String? = nil,
        avd: String? = nil,
        form: DeviceForm? = nil,
        model: String? = nil,
        owner: DeviceLeaseOwner,
        worktree: String? = nil,
        branch: String? = nil,
        claimedAt: Date,
        expiresAt: Date,
        deviceTabID: UUID? = nil,
        deviceTabCreatedByClaim: Bool = false,
        remote: Remote? = nil,
        installed: Installed? = nil
    ) {
        self.kind = kind
        self.serial = serial
        self.avd = avd
        self.form = form
        self.model = model
        self.owner = owner
        self.worktree = worktree
        self.branch = branch
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
        self.deviceTabID = deviceTabID
        self.deviceTabCreatedByClaim = deviceTabCreatedByClaim
        self.remote = remote
        self.installed = installed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DeviceKind.self, forKey: .kind)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
        avd = try container.decodeIfPresent(String.self, forKey: .avd)
        // An unknown form from a newer writer reads as unclassified rather than failing the file.
        form = try? container.decodeIfPresent(DeviceForm.self, forKey: .form)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        owner = try container.decode(DeviceLeaseOwner.self, forKey: .owner)
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        claimedAt = try container.decode(Date.self, forKey: .claimedAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        deviceTabID = try container.decodeIfPresent(UUID.self, forKey: .deviceTabID)
        deviceTabCreatedByClaim = try container.decodeIfPresent(Bool.self, forKey: .deviceTabCreatedByClaim) ?? false
        remote = try container.decodeIfPresent(Remote.self, forKey: .remote)
        installed = try container.decodeIfPresent(Installed.self, forKey: .installed)
    }
}

/// A device on its way to a lease: an AVD booting (`avd:<id>`), or a remote device being reserved
/// (`claim:<uuid>`). It keeps a second claimant from starting the same one.
nonisolated struct PendingDevice: Codable, Equatable, Sendable {
    var owner: DeviceLeaseOwner
    var kind: DeviceKind
    var avd: String?
    var model: String?
    var deviceTabID: UUID?
    var startedAt: Date
    var expiresAt: Date
    var error: String?
}

/// `registry.json`. Only leased devices have entries: a device is free when adb lists it and this
/// doesn't. Local leases are keyed by adb serial, remote ones by `remote:<reservationID>`.
nonisolated struct DeviceRegistry: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let pendingAVDPrefix = "avd:"
    static let pendingClaimPrefix = "claim:"
    /// A remote lease outlives its expiry this long, so the app that holds the reservation
    /// reaps it first and ends the reservation with it.
    static let remoteReapGrace: TimeInterval = 300

    var version = currentVersion
    var devices: [String: DeviceLease] = [:]
    var pending: [String: PendingDevice] = [:]

    static func pendingKey(avd: String) -> String { pendingAVDPrefix + avd }
    static func pendingKey(claim: UUID) -> String { pendingClaimPrefix + claim.uuidString }
    static func remoteKey(reservationID: String) -> String { "remote:" + reservationID }

    /// `key` itself when it names a lease, else the remote lease whose current adb serial it is.
    func leaseKey(for serialOrKey: String) -> String? {
        if devices[serialOrKey] != nil { return serialOrKey }
        return devices.first { $0.value.kind == .remote && $0.value.serial == serialOrKey }?.key
    }

    /// Remote leases by their current adb serial, which adb lists like any USB device.
    var remoteLeasesBySerial: [String: (key: String, lease: DeviceLease)] {
        var bySerial: [String: (key: String, lease: DeviceLease)] = [:]
        for (key, lease) in devices where lease.kind == .remote {
            if let serial = lease.serial { bySerial[serial] = (key, lease) }
        }
        return bySerial
    }

    /// AVDs with a boot in flight.
    var pendingAVDs: Set<String> {
        Set(pending.keys.filter { $0.hasPrefix(Self.pendingAVDPrefix) }.map { String($0.dropFirst(Self.pendingAVDPrefix.count)) })
    }

    /// Drops what no longer holds a device, and returns a line for each. A local lease goes when
    /// it expires, when its serial leaves `adb devices` (offline and unauthorized still count as
    /// present), or when its emulator serial now belongs to another AVD. A remote lease goes only
    /// on expiry, after `remoteReapGrace`: its adb port changes on every reconnect. An empty adb
    /// list proves nothing, since a restarting adb server briefly lists no devices, so it vanishes
    /// no lease; those wait for their expiry.
    @discardableResult
    mutating func reap(liveSerials: Set<String>, emulatorAVDs: [String: String], now: Date) -> [String] {
        var messages: [String] = []
        for key in devices.keys.sorted() {
            guard let lease = devices[key] else { continue }
            if lease.kind == .remote {
                guard lease.expiresAt.addingTimeInterval(Self.remoteReapGrace) < now else { continue }
                messages.append("reaped expired lease on \(key) (\(lease.owner))")
            } else if lease.expiresAt < now {
                messages.append("reaped expired lease on \(key) (\(lease.owner))")
            } else if !liveSerials.isEmpty, !liveSerials.contains(key) {
                messages.append("reaped lease on vanished device \(key) (\(lease.owner))")
            } else if lease.kind == .emulator, let leased = lease.avd, let running = emulatorAVDs[key], running != leased {
                messages.append("reaped lease on \(key) (\(lease.owner)): it now runs \(running), not \(leased)")
            } else {
                continue
            }
            devices[key] = nil
        }
        for key in pending.keys.sorted() {
            guard let entry = pending[key], entry.expiresAt < now else { continue }
            messages.append("reaped stale pending \(key) (\(entry.owner))")
            pending[key] = nil
        }
        return messages
    }
}

nonisolated enum DeviceRegistryCodec {
    enum DecodeError: Error, Equatable {
        case unreadable(String)
        /// Written by a newer Plume; never overwrite it.
        case tooNew(Int)
    }

    private struct VersionProbe: Decodable {
        var version: Int?
    }

    /// Dates are whole epoch seconds.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64(date.timeIntervalSince1970.rounded(.down)))
        }
        return encoder
    }

    static func encode(_ registry: DeviceRegistry) throws -> Data {
        try makeEncoder().encode(registry) + Data("\n".utf8)
    }

    static func decode(_ data: Data) throws -> DeviceRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let version: Int?
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw DecodeError.unreadable(describe(error))
        }
        if let version, version > DeviceRegistry.currentVersion { throw DecodeError.tooNew(version) }
        do {
            var registry = try decoder.decode(DeviceRegistry.self, from: data)
            registry.version = DeviceRegistry.currentVersion
            return registry
        } catch {
            throw DecodeError.unreadable(describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context): context.debugDescription
        case DecodingError.keyNotFound(let key, _): "missing '\(key.stringValue)'"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "bad value at '\(context.codingPath.map(\.stringValue).joined(separator: "."))'"
        default: error.localizedDescription
        }
    }
}

/// `registry.json` and its `lock`. Every Plume build and every `plume` outside Plume share the one
/// directory, so leases mean the same thing to all of them.
nonisolated final class DeviceRegistryStore: Sendable {
    static let fileName = "registry.json"

    static var defaultDirectory: String {
        (CLISocket.releaseApplicationSupport as NSString).appendingPathComponent("devices")
    }

    let directory: String

    init(directory: String = DeviceRegistryStore.defaultDirectory) {
        self.directory = directory
    }

    var registryFile: String { "\(directory)/\(Self.fileName)" }

    /// A missing file is an empty registry. An unreadable one throws rather than read as empty,
    /// since the next save would replace every lease in it.
    func load() throws -> DeviceRegistry {
        guard let data = FileManager.default.contents(atPath: registryFile) else { return DeviceRegistry() }
        do {
            return try DeviceRegistryCodec.decode(data)
        } catch DeviceRegistryCodec.DecodeError.tooNew(let version) {
            throw CLIFailure("\(registryFile) has version \(version) — this plume is too old")
        } catch DeviceRegistryCodec.DecodeError.unreadable(let reason) {
            throw CLIFailure("\(registryFile) is unreadable (\(reason)); move it aside to start a new registry")
        }
    }

    /// Best effort: an entry left behind expires on its own.
    func dropPending(_ key: String) {
        try? withLock {
            var registry = try load()
            if registry.pending.removeValue(forKey: key) != nil { try save(registry) }
        }
    }

    func save(_ registry: DeviceRegistry) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var template = Array("\(directory)/.registry.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else {
            throw CLIFailure("could not write \(registryFile): \(String(cString: strerror(errno)))")
        }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: DeviceRegistryCodec.encode(registry))
            try handle.close()
            guard rename(temporary, registryFile) == 0 else {
                throw CLIFailure("could not write \(registryFile): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// Runs `body` holding an exclusive `flock` on `<directory>/lock`. Not reentrant: a nested
    /// call deadlocks.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open("\(directory)/lock", O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CLIFailure("could not open \(directory)/lock: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw CLIFailure("could not lock \(directory)/lock: \(String(cString: strerror(errno)))")
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
