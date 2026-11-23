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

    /// `isCancelled` kills the command, which then throws `CancellationError`.
    static func tart(_ arguments: [String], isCancelled: () -> Bool) throws {
        guard let tart = locateTart() else {
            throw Failure(message: "tart not found; install it with `brew tap openai/tools && brew install tart`")
        }
        let result = try ChildProcess.run(
            executable: tart, arguments: arguments, timeout: .seconds(VMPaths.tartTimeout), isCancelled: isCancelled
        )
        if isCancelled() { throw CancellationError() }
        guard result.status == 0, !result.timedOut else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "`tart \(arguments.joined(separator: " "))` failed: \(detail.isEmpty ? "exit \(result.status)" : detail)")
        }
    }

    /// `tart clone` copies the base's ecid, which would give two clones one machine identity. The
    /// clone is built under a temporary name and renamed last, so a crash midway never leaves a
    /// clone at `name` that still has the base's ecid. A clone that fails or is cancelled removes
    /// the partial copy directly, since `tart delete` would be cancelled too.
    static func clone(base: String, to name: String, isCancelled: () -> Bool) throws {
        let partial = name + "-partial"
        if vmExists(partial) { try delete(partial, isCancelled: isCancelled) }
        do {
            try tart(["clone", base, partial], isCancelled: isCancelled)
            try writeFreshECID(cloneDirectory: vmDirectory(partial))
            try tart(["rename", partial, name], isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: vmDirectory(partial))
            throw error
        }
    }

    static func delete(_ name: String, isCancelled: () -> Bool) throws {
        try tart(["delete", name], isCancelled: isCancelled)
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
            "-o", "IdentitiesOnly=yes",
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

    static let readinessSeparator = "--plume-readiness--"
    /// The guest's MAC addresses, then its console users.
    static let readinessQuery = "ifconfig | awk '$1 == \"ether\" { print $2 }'; echo \(readinessSeparator); ioreg -n Root -d1 -a"

    /// Whether `readinessQuery`'s output came from the guest with `mac`, not a different guest that
    /// was handed the same address.
    static func readinessShowsMAC(_ output: String, mac: String) -> Bool {
        let parts = output.components(separatedBy: readinessSeparator + "\n")
        guard parts.count == 2 else { return false }
        let wanted = normalizeMAC(mac)
        return parts[0].split(whereSeparator: \.isNewline).contains { normalizeMAC(String($0)) == wanted }
    }

    /// Whether `readinessQuery`'s output shows the guest with `mac` ready.
    static func isReady(readinessOutput output: String, mac: String) -> Bool {
        let parts = output.components(separatedBy: readinessSeparator + "\n")
        return readinessShowsMAC(output, mac: mac) && consoleIsReady(ioregPlist: Data(parts[1].utf8))
    }

    /// Shuts the guest down only if it has `mac`, so a stale address never reaches another clone.
    /// `ifconfig` prints every octet as two digits, and Tart's config may not.
    static func shutdownCommand(mac: String) -> String {
        let padded = normalizeMAC(mac).split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":")
        return "ifconfig | grep -qiF 'ether \(padded)' && sudo shutdown -h now"
    }

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
/// The holder writes its pid and start time into the file, so a check for a free clone reads
/// instead of locking, and never blocks a real acquisition. The start time keeps a crashed holder's
/// pid, reused by another process, from reading as a holder.
nonisolated final class VMCloneLock: @unchecked Sendable {
    let path: String
    private var descriptor: Int32

    static let acquireRetry: Duration = .seconds(1)

    struct Holder: Equatable {
        var pid: pid_t
        var startSeconds: UInt64
        var startMicroseconds: UInt64

        var record: String { "\(pid) \(startSeconds) \(startMicroseconds)\n" }

        init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        init?(record: String) {
            let fields = record.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = pid_t(fields[0]), pid > 0,
                  let seconds = UInt64(fields[1]), let microseconds = UInt64(fields[2])
            else { return nil }
            self.init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
        }

        /// Nil when the process doesn't exist.
        static func running(pid: pid_t) -> Holder? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Holder(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        }
    }

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    /// Blocks briefly on a contended lock, since an older Plume's check for a free clone holds it
    /// for a moment.
    static func acquire(path: String) -> VMCloneLock? {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        let deadline = ContinuousClock.now + acquireRetry
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
                close(descriptor)
                return nil
            }
            usleep(50_000)
        }
        let pid = getpid()
        let record = Array((Holder.running(pid: pid) ?? Holder(pid: pid, startSeconds: 0, startMicroseconds: 0)).record.utf8)
        ftruncate(descriptor, 0)
        _ = pwrite(descriptor, record, record.count, 0)
        return VMCloneLock(path: path, descriptor: descriptor)
    }

    /// Whether another live process holds the lock. This process's own lock never counts, since
    /// `VMManager` already knows which of its slots hold theirs.
    static func isHeldElsewhere(path: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        if let recorded = Holder(record: text) {
            return recorded.pid != getpid() && Holder.running(pid: recorded.pid) == recorded
        }
        guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, pid != getpid() else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func release() {
        guard descriptor >= 0 else { return }
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
