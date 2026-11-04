import Foundation

/// One line of `adb mdns services`.
nonisolated struct ADBMDNSService: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A phone showing a pairing QR code or pairing code.
        case pairing
        /// A paired phone with Wireless debugging on, ready for `adb connect`.
        case connect
        case other(String)
    }

    let instance: String
    let kind: Kind
    /// `host:port`.
    let address: String

    var host: String { ADBWireless.host(of: address) }
}

/// The text a phone scans under Wireless debugging ▸ Pair device with QR code. The phone then
/// advertises a pairing service named `name`, and `password` is the code `adb pair` sends.
nonisolated struct ADBPairingQR: Hashable, Sendable {
    let name: String
    let password: String

    var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

    /// Hex only, so neither field needs the QR format's escaping.
    static func random() -> ADBPairingQR {
        ADBPairingQR(name: "plume-" + randomHex(bytes: 5), password: randomHex(bytes: 6))
    }

    private static func randomHex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

nonisolated enum ADBCommandOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)
}

/// How Plume names a physical device on a tab. A USB device is its adb serial, which is the
/// phone's own serial number. A Wi-Fi device's adb serial is an address or an mDNS name that
/// changes with every connection, so the tab keeps `wifi:<ro.serialno>` instead.
nonisolated enum PhysicalDeviceIdentity {
    static let wifiPrefix = "wifi:"

    static func wifi(hardwareSerial: String) -> String { wifiPrefix + hardwareSerial }

    static func isWifi(_ identifier: String) -> Bool { identifier.hasPrefix(wifiPrefix) }

    /// The phone's serial number an identifier names: the part after `wifi:`, or a USB serial as is.
    static func hardwareSerial(of identifier: String) -> String {
        isWifi(identifier) ? String(identifier.dropFirst(wifiPrefix.count)) : identifier
    }
}

extension PhysicalDevice {
    /// Connected over Wi-Fi: a `host:port` serial, or the name adb gives an mDNS auto-connect.
    /// A remote device's `localhost:` serial is a tunnel, not Wi-Fi.
    nonisolated var isNetwork: Bool { ADBWireless.isNetworkSerial(serial) }
}

nonisolated enum ADBWireless {
    static let pairingServiceType = "_adb-tls-pairing._tcp"
    static let connectServiceType = "_adb-tls-connect._tcp"

    static func isNetworkSerial(_ serial: String) -> Bool {
        if serial.hasPrefix("localhost:") || serial.hasPrefix("emulator-") { return false }
        if serial.contains("." + connectServiceType) { return true }
        return address(serial) != nil
    }

    /// `host:port` with a numeric port, trimmed, or nil.
    static func address(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = trimmed[..<colon]
        let port = trimmed[trimmed.index(after: colon)...]
        guard !host.isEmpty, !host.contains(where: \.isWhitespace),
              let number = Int(port), (1...65535).contains(number)
        else { return nil }
        return trimmed
    }

    static func host(of address: String) -> String {
        guard let colon = address.lastIndex(of: ":") else { return address }
        return String(address[..<colon])
    }

    /// Parses `adb mdns services`. Fields are tab-separated in current adb and space-separated in
    /// some older builds, and a service type may carry a trailing dot.
    static func parseServices(_ output: String) -> [ADBMDNSService] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let typeIndex = fields.firstIndex(where: { $0.hasPrefix("_adb") }), typeIndex > 0,
                  let address = fields.dropFirst(typeIndex + 1).last.flatMap(address)
            else { return nil }
            let type = fields[typeIndex].hasSuffix(".") ? String(fields[typeIndex].dropLast()) : fields[typeIndex]
            let kind: ADBMDNSService.Kind = switch type {
            case pairingServiceType: .pairing
            case connectServiceType: .connect
            default: .other(type)
            }
            return ADBMDNSService(instance: fields[..<typeIndex].joined(separator: " "), kind: kind, address: address)
        }
    }

    /// `adb mdns check` prints the daemon's version when mDNS works, and an error otherwise.
    static func parseMDNSCheck(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("mdns daemon version") && !text.contains("unavailable")
    }

    /// adb exits 0 from a failed pair, so only the text tells.
    static func parsePair(_ output: String) -> ADBCommandOutcome {
        if output.contains("Successfully paired") { return .succeeded }
        return .failed(failureMessage(output, fallback: "Pairing failed."))
    }

    /// adb exits 0 from a failed connect too.
    static func parseConnect(_ output: String) -> ADBCommandOutcome {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("connected to") || $0.hasPrefix("already connected to") }) {
            return .succeeded
        }
        return .failed(failureMessage(output, fallback: "Connecting failed."))
    }

    static func parseSerialNumber(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty, line != "unknown", !line.lowercased().hasPrefix("error"),
              !line.contains(where: \.isWhitespace)
        else { return nil }
        return line
    }

    private static func failureMessage(_ output: String, fallback: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.last else { return fallback }
        for prefix in ["Failed: ", "error: ", "adb: "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // MARK: Running adb

    static func mdnsAvailable(adb: URL) async -> Bool {
        await run(adb, ["mdns", "check"], timeout: 5).map { parseMDNSCheck($0.combined) } ?? false
    }

    static func services(adb: URL) async -> [ADBMDNSService] {
        await run(adb, ["mdns", "services"], timeout: 5).map { parseServices($0.stdout) } ?? []
    }

    static func pair(adb: URL, address: String, code: String) async -> ADBCommandOutcome {
        guard let result = await run(adb, ["pair", address, code], timeout: 20) else {
            return .failed("adb didn't answer while pairing.")
        }
        return parsePair(result.combined)
    }

    static func connect(adb: URL, address: String) async -> ADBCommandOutcome {
        guard let result = await run(adb, ["connect", address], timeout: 15) else {
            return .failed("adb didn't answer while connecting.")
        }
        return parseConnect(result.combined)
    }

    /// The phone's `ro.serialno`, the same across every connection.
    static func serialNumber(adb: URL, serial: String) async -> String? {
        await run(adb, ["-s", serial, "get-serialno"], timeout: 5).flatMap { parseSerialNumber($0.stdout) }
    }

    /// Nil when adb couldn't run or overran `timeout`. Cancelling the task kills it.
    private static func run(_ adb: URL, _ arguments: [String], timeout: Int) async -> ChildProcessResult? {
        guard let result = try? await ChildProcess.run(executable: adb.path, arguments: arguments, timeout: .seconds(timeout)),
              !result.timedOut
        else { return nil }
        return result
    }
}

private extension ChildProcessResult {
    /// adb reports pair, connect and mdns results on either stream.
    nonisolated var combined: String { stdout + "\n" + stderr }
}
