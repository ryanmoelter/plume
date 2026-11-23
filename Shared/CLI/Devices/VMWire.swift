import Foundation

/// A slot's place in its boot: `idle → reserved → cloning → starting → ready → stopping`, or `failed`.
nonisolated enum VMSlotState: String, Codable, Equatable, Sendable {
    case idle, reserved, cloning, starting, ready, stopping, failed
}

/// One VM slot as the app reports it over the socket. `docs/vm-testing.md` is the reference.
nonisolated struct VMLeaseInfo: Codable, Equatable, Sendable {
    var key: String
    var state: VMSlotState
    var clone: String
    var ip: String?
    var user: String = VMPaths.guestUser
    var sshKey: String = VMPaths.sshKey
    var share: String
    var guestShare: String = VMPaths.guestShare
    var worktree: String?
    var guestWorktree: String?
    var controlSocket: String
    var owner: DeviceLeaseOwner?
    var branch: String?
    var claimedAt: Date?
    var expiresAt: Date?
    var installed: DeviceLease.Installed?
    var error: String?
    /// The boot failed because the host already runs as many macOS guests as Virtualization allows.
    var poolFull: Bool?
    /// Another Plume holds this slot's clone, so this app can't boot it.
    var heldElsewhere: Bool?
}

/// Where VM state lives. Every build uses the installed app's data directory, so the clone locks
/// that keep two apps off one clone are the same files for all of them.
nonisolated enum VMPaths {
    static let slotCount = 2
    static let guestUser = "admin"
    static let guestShareRoot = "/Volumes/My Shared Files"
    static let guestShare = guestShareRoot + "/share"
    static let guestWorktree = guestShareRoot + "/worktree"
    static let keyPrefix = "vm:"
    /// How long the app lets one `tart` command run.
    static let tartTimeout: TimeInterval = 300

    static var directory: String { CLISocket.releaseApplicationSupport + "/vms" }
    static var sshKey: String { directory + "/id_ed25519" }

    static func slotDirectory(_ slot: Int) -> String { directory + "/vm\(slot)" }
    static func share(_ slot: Int) -> String { slotDirectory(slot) + "/share" }
    static func controlSocket(_ slot: Int) -> String { slotDirectory(slot) + "/control.sock" }
    static func lockFile(clone: String) -> String { directory + "/\(clone).lock" }

    static func key(_ slot: Int) -> String { keyPrefix + String(slot) }

    static func slot(fromKey key: String) -> Int? {
        guard key.hasPrefix(keyPrefix), let slot = Int(key.dropFirst(keyPrefix.count)), (1...slotCount).contains(slot) else {
            return nil
        }
        return slot
    }

    static func isKey(_ value: String) -> Bool { value.hasPrefix(keyPrefix) }

    static func cloneName(slot: Int, os: Int) -> String { "plume-\(os)-\(slot)" }
    static func baseName(os: Int) -> String { "plume-base-\(os)" }
}
