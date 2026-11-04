import Foundation
import Observation
import Synchronization

/// The adb commands pairing runs, so tests can script them.
nonisolated protocol ADBWirelessRunning: Sendable {
    func mdnsAvailable() async -> Bool
    func services() async -> [ADBMDNSService]
    func pair(address: String, code: String) async -> ADBCommandOutcome
    func connect(address: String) async -> ADBCommandOutcome
}

nonisolated final class LiveADBWireless: ADBWirelessRunning {
    static let shared = LiveADBWireless()

    private let located = Mutex<URL?>(nil)

    func mdnsAvailable() async -> Bool {
        guard let adb = await adb() else { return false }
        return await ADBWireless.mdnsAvailable(adb: adb)
    }

    func services() async -> [ADBMDNSService] {
        guard let adb = await adb() else { return [] }
        return await ADBWireless.services(adb: adb)
    }

    func pair(address: String, code: String) async -> ADBCommandOutcome {
        guard let adb = await adb() else { return .failed("adb wasn't found.") }
        return await ADBWireless.pair(adb: adb, address: address, code: code)
    }

    func connect(address: String) async -> ADBCommandOutcome {
        guard let adb = await adb() else { return .failed("adb wasn't found.") }
        return await ADBWireless.connect(adb: adb, address: address)
    }

    private func adb() async -> URL? {
        if let url = located.withLock({ $0 }) { return url }
        let url = await AndroidSDKLocator.locate().sdk?.adbURL
        located.withLock { $0 = url }
        return url
    }
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
        adb: ADBWirelessRunning = LiveADBWireless.shared,
        discovery: PhysicalDeviceDiscovery = .shared,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.adb = adb
        self.discovery = discovery
        self.sleep = sleep
        self.now = now
    }

    /// Shows a fresh QR code and waits for a phone to scan it.
    func startQRCode() {
        cancel()
        qr = .random()
        phase = .waitingForScan
        let qr = qr
        work = Task { [weak self, adb, sleep] in
            guard await adb.mdnsAvailable() else {
                guard !Task.isCancelled else { return }
                self?.phase = .mdnsUnavailable
                return
            }
            while !Task.isCancelled {
                if let service = await adb.services().first(where: { $0.kind == .pairing && $0.instance == qr.name }) {
                    guard !Task.isCancelled else { return }
                    await self?.pairAndConnect(address: service.address, code: qr.password, connectAddress: nil)
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
        work = Task { [weak self] in await self?.pairAndConnect(address: address, code: code, connectAddress: connect) }
    }

    /// Connects an already paired phone at the address on its Wireless debugging screen.
    func connect(address: String) {
        cancel()
        guard let address = ADBWireless.address(address) else {
            phase = .pairedNotConnected(Self.enterConnectAddress)
            return
        }
        phase = .connecting
        work = Task { [weak self] in
            await self?.waitForPhone(host: ADBWireless.host(of: address), connectAddress: address, addressGrace: .zero)
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    private static let enterConnectAddress =
        "Enter the IP address and port from the device's Wireless debugging screen, like 192.168.1.20:41234."

    private func pairAndConnect(address: String, code: String, connectAddress: String?) async {
        phase = .pairing
        let outcome = await adb.pair(address: address, code: code)
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return
        }
        phase = .connecting
        await waitForPhone(host: ADBWireless.host(of: address), connectAddress: connectAddress, addressGrace: Self.enteredAddressGrace)
    }

    private func waitForPhone(host: String, connectAddress: String?, addressGrace: Duration) async {
        let start = now()
        var attempted: Set<String> = []
        var connectFailure: String?
        while true {
            await discovery.refresh()
            let services = await adb.services().filter { $0.kind == .connect && $0.host == host }
            guard !Task.isCancelled else { return }
            if let phone = discovery.devices.first(where: { Self.isPhone($0, at: host, services: services) }) {
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
                if case .failed(let message) = await adb.connect(address: address) { connectFailure = message }
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
    private static func isPhone(_ device: PhysicalDevice, at host: String, services: [ADBMDNSService]) -> Bool {
        guard device.isReady, device.isNetwork else { return false }
        if ADBWireless.address(device.serial) != nil { return ADBWireless.host(of: device.serial) == host }
        return services.contains { device.serial.hasPrefix($0.instance + ".") }
    }
}
