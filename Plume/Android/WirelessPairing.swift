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
/// After a pair, adb normally connects the phone by itself through mDNS. If no new Wi-Fi device
/// shows up after a few polls, Plume looks up the phone's connect service at the address it
/// paired with and runs `adb connect` itself.
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
    /// Polls before Plume connects by hand rather than waiting on adb's auto-connect.
    static let autoConnectPolls = 3
    static let connectPolls = 15

    private(set) var phase: Phase = .idle
    private(set) var qr = ADBPairingQR.random()

    @ObservationIgnored private let adb: ADBWirelessRunning
    @ObservationIgnored private let discovery: PhysicalDeviceDiscovery
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var work: Task<Void, Never>?

    init(
        adb: ADBWirelessRunning = LiveADBWireless(),
        discovery: PhysicalDeviceDiscovery = .shared,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.adb = adb
        self.discovery = discovery
        self.sleep = sleep
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
        await discovery.refresh()
        let before = Set(discovery.devices.map(\.serial))
        let outcome = await adb.pair(address: address, code: code)
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return
        }
        phase = .connecting
        let host = ADBWireless.host(of: address)
        var connectedAddress: String?
        var connectFailure: String?
        for poll in 0..<Self.connectPolls {
            await discovery.refresh()
            guard !Task.isCancelled else { return }
            let ready = discovery.devices.filter { $0.isReady && $0.isNetwork }
            if let device = ready.first(where: { !before.contains($0.serial) || $0.serial == connectedAddress }) {
                phase = .connected(device)
                return
            }
            if poll >= Self.autoConnectPolls, connectedAddress == nil,
               let service = await adb.services().first(where: { $0.kind == .connect && $0.host == host }) {
                guard !Task.isCancelled else { return }
                switch await adb.connect(address: service.address) {
                case .succeeded: connectedAddress = service.address
                case .failed(let message): connectFailure = message
                }
                guard !Task.isCancelled else { return }
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
}
