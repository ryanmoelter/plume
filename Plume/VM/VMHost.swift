import Darwin
import Foundation
import Virtualization

/// The host side of a VM: Tart for clone and delete, the DHCP leases for the guest's address, ssh
/// into the guest, and the clone locks. Everything here blocks or spawns, so callers stay off the
/// main actor. `docs/vm-testing.md` records why each piece works the way it does.
nonisolated enum VMHost {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static let tartTimeout: Duration = .seconds(300)
    static let sshConnectTimeout = 3

    // MARK: Tart

    /// A GUI-launched app has no shell PATH, so Homebrew's prefixes are searched too.
    static func locateTart(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathEntries + ["/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.lazy.map { ($0 as NSString).appendingPathComponent("tart") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func tartHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["TART_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".tart", directoryHint: .isDirectory)
    }

    static func vmDirectory(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        tartHome(environment: environment).appending(path: "vms/\(name)", directoryHint: .isDirectory)
    }

    static func vmExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: vmDirectory(name).appending(path: TartVMConfig.fileName).path)
    }

    static func tart(_ arguments: [String]) throws {
        guard let tart = locateTart() else {
            throw Failure(message: "tart not found; install it with `brew tap openai/tools && brew install tart`")
        }
        let result = try ChildProcess.run(executable: tart, arguments: arguments, timeout: tartTimeout)
        guard result.status == 0, !result.timedOut else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "`tart \(arguments.joined(separator: " "))` failed: \(detail.isEmpty ? "exit \(result.status)" : detail)")
        }
    }

    /// `tart clone` copies the base's ecid, which would give two clones one machine identity.
    static func clone(base: String, to name: String) throws {
        try tart(["clone", base, name])
        try writeFreshECID(cloneDirectory: vmDirectory(name))
    }

    static func delete(_ name: String) throws {
        try tart(["delete", name])
    }

    static func writeFreshECID(cloneDirectory: URL) throws {
        let file = cloneDirectory.appending(path: TartVMConfig.fileName)
        let rewritten = try TartVMConfig.rewritingECID(in: Data(contentsOf: file), to: VZMacMachineIdentifier().dataRepresentation)
        try rewritten.write(to: file, options: .atomic)
    }

    // MARK: Address

    static let dhcpLeasesFile = "/var/db/dhcpd_leases"

    /// `dhcpd_leases` drops each octet's leading zero (`06` reads `6`), so both sides are
    /// compared without them.
    static func normalizeMAC(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { octet in
            let trimmed = octet.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }

    struct DHCPLease: Equatable {
        var ip: String
        var mac: String
        /// When the lease expires, in seconds since 1970; the newest lease for a MAC wins.
        var expiry: UInt64
    }

    static func parseDHCPLeases(_ text: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                fields = [:]
            } else if line == "}" {
                if let ip = fields["ip_address"], let hardware = fields["hw_address"] {
                    let mac = hardware.split(separator: ",", maxSplits: 1).last.map(String.init) ?? hardware
                    let expiry = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
                    leases.append(DHCPLease(ip: ip, mac: normalizeMAC(mac), expiry: expiry))
                }
                fields = [:]
            } else if let equals = line.firstIndex(of: "=") {
                fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        return leases
    }

    static func ipAddress(forMAC mac: String, leasesText: String) -> String? {
        let wanted = normalizeMAC(mac)
        return parseDHCPLeases(leasesText).filter { $0.mac == wanted }.max { $0.expiry < $1.expiry }?.ip
    }

    static func ipAddress(forMAC mac: String) -> String? {
        guard let text = try? String(contentsOfFile: dhcpLeasesFile, encoding: .utf8) else { return nil }
        return ipAddress(forMAC: mac, leasesText: text)
    }

    // MARK: SSH

    static func sshArguments(ip: String, command: String) -> [String] {
        [
            "-i", VMPaths.sshKey,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=\(sshConnectTimeout)",
            "\(VMPaths.guestUser)@\(ip)",
            command,
        ]
    }

    static func ssh(ip: String, command: String, timeout: Duration = .seconds(15)) async throws -> ChildProcessResult {
        try await ChildProcess.run(executable: "/usr/bin/ssh", arguments: sshArguments(ip: ip, command: command), timeout: timeout)
    }

    // MARK: Readiness

    static let consoleQuery = "ioreg -n Root -d1 -a"

    /// The guest is ready once `user` is on the console with its login done and the screen
    /// unlocked; `launchctl print gui/<uid>` succeeds well before that.
    static func consoleIsReady(ioregPlist: Data, user: String = VMPaths.guestUser) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(from: ioregPlist, format: nil) else { return false }
        return consoleUsers(in: root).contains { entry in
            entry["kCGSSessionUserNameKey"] as? String == user
                && entry["kCGSSessionOnConsoleKey"] as? Bool == true
                && entry["kCGSessionLoginDoneKey"] as? Bool == true
                && entry["CGSSessionScreenIsLocked"] as? Bool != true
        }
    }

    private static func consoleUsers(in node: Any) -> [[String: Any]] {
        if let dictionary = node as? [String: Any] {
            if let users = dictionary["IOConsoleUsers"] as? [[String: Any]] { return users }
            return dictionary.values.flatMap(consoleUsers(in:))
        }
        if let array = node as? [Any] { return array.flatMap(consoleUsers(in:)) }
        return []
    }
}

/// An `flock` on `vms/<clone>.lock`, held for the VM's whole life so that no other Plume boots or
/// resets the same clone. The kernel drops it when the process dies, so a crash frees the clone.
nonisolated final class VMCloneLock: @unchecked Sendable {
    let path: String
    private var descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    static func acquire(path: String) -> VMCloneLock? {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return VMCloneLock(path: path, descriptor: descriptor)
    }

    /// Only meaningful for a clone this process doesn't hold: `flock` locks belong to an open file,
    /// so a second open here would read this process's own lock as someone else's.
    static func isFree(path: String) -> Bool {
        guard let lock = acquire(path: path) else { return false }
        lock.release()
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
