import Foundation
import Observation

/// The adb commands pairing runs, so tests can script them.
nonisolated protocol ADBWirelessRunning: Sendable {
    func mdnsAvailable() async -> Bool
    func services() async -> [ADBMDNSService]
    func pair(address: String, code: String) async -> ADBCommandOutcome
    func connect(address: String) async -> ADBCommandOutcome
}

nonisolated struct LiveADBWireless: ADBWirelessRunning {
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
        await AndroidSDKLocator.locate().sdk?.adbURL
    }
}

/// Pairs a phone over Wireless debugging and waits until adb lists it ready.
///
/// After a pair, adb normally connects the phone by itself through mDNS. The phone is the ready
/// Wi-Fi device at the host it paired from: a `host:port` serial on that host, or an mDNS serial
/// named by a connect service on it. If none shows up within a few seconds, Plume runs
/// `adb connect` itself, once per connect service at that host.
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
        case failed(String)
    }

    static let pollInterval: Duration = .seconds(1)
    /// How long Plume waits on adb's auto-connect before connecting by hand.
    static let autoConnectGrace: Duration = .seconds(3)
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
                    await self?.pairAndConnect(address: service.address, code: qr.password)
                    return
                }
                await sleep(Self.pollInterval)
            }
        }
    }

    /// Pairs with the address and six-digit code from Pair device with pairing code.
    func pair(address: String, code: String) {
        cancel()
        let code = code.trimmingCharacters(in: .whitespaces)
        guard let address = ADBWireless.address(address) else {
            phase = .failed("Enter the IP address and port the device shows, like 192.168.1.20:37123.")
            return
        }
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            phase = .failed("Enter the Wi-Fi pairing code the device shows.")
            return
        }
        work = Task { [weak self] in await self?.pairAndConnect(address: address, code: code) }
    }

    func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    private func pairAndConnect(address: String, code: String) async {
        phase = .pairing
        let outcome = await adb.pair(address: address, code: code)
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return
        }
        phase = .connecting
        let host = ADBWireless.host(of: address)
        let start = now()
        var attempted: Set<String> = []
        var connectFailure: String?
        while now() - start < Self.connectDeadline {
            await discovery.refresh()
            let services = await adb.services().filter { $0.kind == .connect && $0.host == host }
            guard !Task.isCancelled else { return }
            if let phone = discovery.devices.first(where: { Self.isPhone($0, at: host, services: services) }) {
                phase = .connected(phone)
                return
            }
            if now() - start >= Self.autoConnectGrace {
                for service in services where !attempted.contains(service.address) {
                    attempted.insert(service.address)
                    if case .failed(let message) = await adb.connect(address: service.address) { connectFailure = message }
                    guard !Task.isCancelled else { return }
                }
            }
            await sleep(Self.pollInterval)
        }
        guard !Task.isCancelled else { return }
        phase = .failed(
            "Paired, but the device didn't connect"
                + (connectFailure.map { ": \($0)" } ?? ".")
                + " Check that it's on the same network, then connect to the IP address and port under Wireless debugging with adb connect."
        )
    }

    /// Already connected counts, so pairing a phone again finds it under either serial form.
    private static func isPhone(_ device: PhysicalDevice, at host: String, services: [ADBMDNSService]) -> Bool {
        guard device.isReady, device.isNetwork else { return false }
        if ADBWireless.address(device.serial) != nil { return ADBWireless.host(of: device.serial) == host }
        return services.contains { device.serial.hasPrefix($0.instance + ".") }
    }
}
