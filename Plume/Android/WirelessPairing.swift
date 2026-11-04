import Foundation
import Observation

/// The adb commands pairing runs, so tests can script them.
nonisolated protocol ADBWirelessRunning: Sendable {
    func mdnsAvailable(adb: URL) async -> Bool
    func services(adb: URL) async -> [ADBMDNSService]
    func pair(adb: URL, address: String, code: String) async -> ADBCommandOutcome
    func connect(adb: URL, address: String) async -> ADBCommandOutcome
}

nonisolated struct LiveADBWireless: ADBWirelessRunning {
    func mdnsAvailable(adb: URL) async -> Bool { await ADBWireless.mdnsAvailable(adb: adb) }
    func services(adb: URL) async -> [ADBMDNSService] { await ADBWireless.services(adb: adb) }
    func pair(adb: URL, address: String, code: String) async -> ADBCommandOutcome {
        await ADBWireless.pair(adb: adb, address: address, code: code)
    }
    func connect(adb: URL, address: String) async -> ADBCommandOutcome { await ADBWireless.connect(adb: adb, address: address) }
}

/// Pairs a phone over Wireless debugging and waits until adb lists it ready.
///
/// After a pair, adb normally connects the phone by itself through mDNS. The phone is the ready
/// Wi-Fi device at the host it paired from: a `host:port` serial on that host, or an mDNS serial
/// named by a connect service on it. While mDNS shows a connect service for the host, Plume
/// leaves the connecting to adb until near the end of the wait, since an `adb connect` of its own
/// would add a second transport for the same phone. Without one, adb can't connect the phone, so
/// Plume connects to the address the user entered from the phone's Wireless debugging screen.
/// Each address is tried once.
@MainActor @Observable
final class WirelessPairing {
    enum Phase: Equatable {
        case idle
        case waitingForScan
        /// adb's mDNS can't see the network, so a QR code can never be found.
        case mdnsUnavailable
        case pairing
        case connecting
        case connected(PhysicalDevice)
        /// Paired, but no connection: the user enters the phone's address and connects.
        case pairedNotConnected(String)
        case failed(String)
    }

    enum ReturnKeyAction: Equatable {
        case pair
        case connect
    }

    /// Once paired, Return connects; pairing again would reuse a code the phone has dropped.
    var returnKeyAction: ReturnKeyAction {
        if case .pairedNotConnected = phase { .connect } else { .pair }
    }

    static let pollInterval: Duration = .seconds(1)
    /// How long adb gets to connect the phone by itself before Plume connects to an entered address.
    static let enteredAddressGrace: Duration = .seconds(3)
    /// How long adb gets to connect a phone mDNS advertises before Plume connects it itself.
    static let autoConnectWindow: Duration = .seconds(14)
    static let connectDeadline: Duration = .seconds(20)

    private(set) var phase: Phase = .idle
    private(set) var qr = ADBPairingQR.random()

    @ObservationIgnored private let adb: ADBWirelessRunning
    @ObservationIgnored private let discovery: PhysicalDeviceDiscovery
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var work: Task<Void, Never>?

    init(
        adb: ADBWirelessRunning = LiveADBWireless(),
        discovery: PhysicalDeviceDiscovery = .shared,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.adb = adb
        self.discovery = discovery
        self.sleep = sleep
        self.now = now
    }

    isolated deinit {
        work?.cancel()
    }

    /// Shows a fresh QR code and waits for a phone to scan it.
    func startQRCode() {
        cancel()
        qr = .random()
        phase = .waitingForScan
        let qr = qr
        work = Task { [weak self, adb, sleep, discovery] in
            let adbURL = await discovery.adb()
            guard !Task.isCancelled else { return }
            guard let adbURL else {
                self?.phase = .failed(Self.adbMissing)
                return
            }
            guard await adb.mdnsAvailable(adb: adbURL) else {
                guard !Task.isCancelled else { return }
                self?.phase = .mdnsUnavailable
                return
            }
            while !Task.isCancelled, self != nil {
                if let service = await adb.services(adb: adbURL).first(where: { $0.kind == .pairing && $0.instance == qr.name }) {
                    guard !Task.isCancelled else { return }
                    await self?.pairAndConnect(adb: adbURL, address: service.address, code: qr.password, connectAddress: nil)
                    return
                }
                await sleep(Self.pollInterval)
            }
        }
    }

    /// Pairs with the address and code from Pair device with pairing code. `connectAddress` is
    /// the IP address and port on the Wireless debugging screen itself, optional.
    func pair(address: String, code: String, connectAddress: String = "") {
        cancel()
        let code = code.trimmingCharacters(in: .whitespaces)
        guard let address = ADBWireless.address(address) else {
            phase = .failed("Enter the IP address and port the pairing dialog shows, like 192.168.1.20:37123.")
            return
        }
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            phase = .failed("Enter the Wi-Fi pairing code the device shows.")
            return
        }
        let trimmed = connectAddress.trimmingCharacters(in: .whitespaces)
        let connect = ADBWireless.address(trimmed)
        guard trimmed.isEmpty || connect != nil else {
            phase = .failed(Self.enterConnectAddress)
            return
        }
        phase = .pairing
        work = Task { [weak self, discovery] in
            let adbURL = await discovery.adb()
            guard !Task.isCancelled else { return }
            guard let adbURL else {
                self?.phase = .failed(Self.adbMissing)
                return
            }
            await self?.pairAndConnect(adb: adbURL, address: address, code: code, connectAddress: connect)
        }
    }

    /// Connects an already paired phone at the address on its Wireless debugging screen, at once,
    /// then waits for adb to list it.
    func connect(address: String) {
        cancel()
        guard let address = ADBWireless.address(address) else {
            phase = .pairedNotConnected(Self.enterConnectAddress)
            return
        }
        phase = .connecting
        work = Task { [weak self, adb, discovery] in
            let adbURL = await discovery.adb()
            guard !Task.isCancelled else { return }
            guard let adbURL else {
                self?.phase = .failed(Self.adbMissing)
                return
            }
            let outcome = await adb.connect(adb: adbURL, address: address)
            guard !Task.isCancelled, let self else { return }
            if case .failed(let message) = outcome {
                phase = .pairedNotConnected("The device didn't connect: \(message) " + Self.enterConnectAddress)
                return
            }
            await waitForPhone(adb: adbURL, host: ADBWireless.host(of: address), connectAddress: nil, addressGrace: .zero, attempted: [address])
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    private static let enterConnectAddress =
        "Enter the IP address and port from the device's Wireless debugging screen, like 192.168.1.20:41234."
    private static let adbMissing = "adb wasn't found."

    private func pairAndConnect(adb adbURL: URL, address: String, code: String, connectAddress: String?) async {
        phase = .pairing
        let outcome = await adb.pair(adb: adbURL, address: address, code: code)
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return
        }
        phase = .connecting
        await waitForPhone(
            adb: adbURL, host: ADBWireless.host(of: address), connectAddress: connectAddress, addressGrace: Self.enteredAddressGrace
        )
    }

    /// `attempted` holds addresses already connected to, which the wait never connects again. The
    /// phone counts on the pairing host or on the host of the address the user entered.
    private func waitForPhone(
        adb adbURL: URL, host: String, connectAddress: String?, addressGrace: Duration, attempted: Set<String> = []
    ) async {
        let start = now()
        var attempted = attempted
        var connectFailure: String?
        let hosts = Set([host] + (connectAddress.map { [ADBWireless.host(of: $0)] } ?? []))
        while true {
            await discovery.refresh()
            let services = await adb.services(adb: adbURL).filter { $0.kind == .connect && hosts.contains($0.host) }
            guard !Task.isCancelled else { return }
            if let phone = discovery.devices.first(where: { Self.isPhone($0, on: hosts, services: services) }) {
                phase = .connected(phone)
                return
            }
            let elapsed = now() - start
            guard elapsed < Self.connectDeadline else { break }
            let addresses: [String] = if !services.isEmpty {
                elapsed >= Self.autoConnectWindow ? services.map(\.address) : []
            } else if let connectAddress, elapsed >= addressGrace {
                [connectAddress]
            } else {
                []
            }
            for address in addresses where !attempted.contains(address) {
                attempted.insert(address)
                if case .failed(let message) = await adb.connect(adb: adbURL, address: address) { connectFailure = message }
                guard !Task.isCancelled else { return }
            }
            await sleep(Self.pollInterval)
        }
        phase = .pairedNotConnected(
            connectFailure.map { "Paired, but the device didn't connect: \($0) " + Self.enterConnectAddress }
                ?? "Paired, but adb didn't connect the device by itself. " + Self.enterConnectAddress
        )
    }

    /// Already connected counts, so pairing a phone again finds it under either serial form.
    private static func isPhone(_ device: PhysicalDevice, on hosts: Set<String>, services: [ADBMDNSService]) -> Bool {
        guard device.isReady, device.isNetwork else { return false }
        if ADBWireless.address(device.serial) != nil { return hosts.contains(ADBWireless.host(of: device.serial)) }
        return services.contains { device.serial.hasPrefix($0.instance + ".") }
    }
}
