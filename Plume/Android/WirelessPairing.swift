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
/// named by a connect service seen on it, or carrying the paired phone's serial number. While
/// mDNS shows a connect service for the host, Plume leaves the connecting to adb until near the
/// end of the wait, since an `adb connect` of its own would add a second transport for the same
/// phone. Without one, the wait ends in `pairedNotConnected`, and the user connects the address
/// from the phone's Wireless debugging screen. Each address is tried once.
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

    /// Finding phones that show Pair device with pairing code, for the pairing-code form.
    enum Browsing: Equatable {
        case stopped
        case searching
        case found
        /// adb's mDNS can't see the network, or adb is missing, so the address is typed.
        case unavailable
        /// No phone appeared within `manualAddressDelay`; the list keeps updating.
        case nothingFound
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
    /// How long adb gets to connect a phone mDNS advertises before Plume connects it itself.
    static let autoConnectWindow: Duration = .seconds(14)
    static let connectDeadline: Duration = .seconds(20)
    /// How long the pairing-code form looks for a phone before offering the address field.
    static let manualAddressDelay: Duration = .seconds(4)

    private(set) var phase: Phase = .idle
    private(set) var qr = ADBPairingQR.random()
    private(set) var browsing = Browsing.stopped
    /// Phones showing Pair device with pairing code, as of the last poll.
    private(set) var pairingServices: [ADBMDNSService] = []
    /// The pairing dialog's `host:port`: a picked phone's, or typed.
    var pairingAddress = ""

    @ObservationIgnored private let adb: ADBWirelessRunning
    @ObservationIgnored private let discovery: PhysicalDeviceDiscovery
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    /// The service `pairingAddress` was filled from, while the user hasn't edited it since.
    @ObservationIgnored private var filledFrom: ADBMDNSService?

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
        browseTask?.cancel()
    }

    /// Polls mDNS for phones showing Pair device with pairing code, until pairing starts or
    /// `cancel()`. A lone phone is picked for the user when no address is set.
    func startBrowsing() {
        stopBrowsing()
        browsing = .searching
        let started = now()
        browseTask = Task { [weak self, adb, sleep, discovery] in
            let adbURL = await discovery.adb()
            guard !Task.isCancelled else { return }
            guard let adbURL, await adb.mdnsAvailable(adb: adbURL) else {
                guard !Task.isCancelled else { return }
                self?.browsing = .unavailable
                return
            }
            while !Task.isCancelled, self != nil {
                let found = await adb.services(adb: adbURL).filter(\.isCodePairing)
                guard !Task.isCancelled else { return }
                self?.receive(found, browsingSince: started)
                await sleep(Self.pollInterval)
            }
        }
    }

    func stopBrowsing() {
        browseTask?.cancel()
        browseTask = nil
        browsing = .stopped
    }

    func select(_ service: ADBMDNSService) {
        fill(from: service)
    }

    private func fill(from service: ADBMDNSService?) {
        filledFrom = service
        pairingAddress = service?.address ?? ""
    }

    /// A phone's model when adb already lists it under the serial number in its service name.
    func displayName(of service: ADBMDNSService) -> String {
        let serial = service.deviceName
        let known = discovery.devices.first { $0.serial == serial || discovery.hardwareSerial(ofIdentifier: $0.serial) == serial }
        guard let known, known.model != nil else { return serial }
        return known.displayName
    }

    private func receive(_ services: [ADBMDNSService], browsingSince started: ContinuousClock.Instant) {
        if services != pairingServices { pairingServices = services }
        if let filled = filledFrom, filled.address != pairingAddress { filledFrom = nil }
        if let filled = filledFrom {
            // A phone re-advertises under its instance name at a new port when its dialog reopens.
            if !services.contains(filled) {
                fill(from: services.first { $0.instance == filled.instance } ?? (services.count == 1 ? services[0] : nil))
            }
        } else if services.count == 1, pairingAddress.trimmingCharacters(in: .whitespaces).isEmpty {
            fill(from: services[0])
        }
        let status: Browsing = if !services.isEmpty {
            .found
        } else if now() - started >= Self.manualAddressDelay {
            .nothingFound
        } else {
            .searching
        }
        if status != browsing { browsing = status }
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
                    await self?.pairAndConnect(adb: adbURL, address: service.address, code: qr.password, pairedSerial: nil)
                    return
                }
                await sleep(Self.pollInterval)
            }
        }
    }

    /// Pairs with the address and code from Pair device with pairing code.
    func pair(address: String, code: String) {
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
        let pairedSerial = pairingServices.first { $0.address == address }.map(\.deviceName)
        phase = .pairing
        work = Task { [weak self, discovery] in
            let adbURL = await discovery.adb()
            guard !Task.isCancelled else { return }
            guard let adbURL else {
                self?.phase = .failed(Self.adbMissing)
                return
            }
            await self?.pairAndConnect(adb: adbURL, address: address, code: code, pairedSerial: pairedSerial)
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
            await waitForPhone(adb: adbURL, host: ADBWireless.host(of: address), pairedSerial: nil, attempted: [address])
        }
    }

    func cancel() {
        stopBrowsing()
        work?.cancel()
        work = nil
        phase = .idle
    }

    private static let enterConnectAddress =
        "Enter the IP address and port from the device's Wireless debugging screen, like 192.168.1.20:41234."
    private static let adbMissing = "adb wasn't found."

    /// `pairedSerial` is the serial number in the pairing service's name, when the user picked one.
    private func pairAndConnect(adb adbURL: URL, address: String, code: String, pairedSerial: String?) async {
        phase = .pairing
        let outcome = await adb.pair(adb: adbURL, address: address, code: code)
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome {
            phase = .failed(message)
            return
        }
        phase = .connecting
        await waitForPhone(adb: adbURL, host: ADBWireless.host(of: address), pairedSerial: pairedSerial)
    }

    /// `attempted` holds addresses already connected to, which the wait never connects again.
    private func waitForPhone(adb adbURL: URL, host: String, pairedSerial: String?, attempted: Set<String> = []) async {
        let start = now()
        var attempted = attempted
        var connectFailure: String?
        // adb can list the phone a poll after mDNS stops advertising it.
        var seenServices: Set<String> = []
        while true {
            await discovery.refreshListing()
            let services = await adb.services(adb: adbURL).filter { $0.kind == .connect && $0.host == host }
            guard !Task.isCancelled else { return }
            seenServices.formUnion(services.map(\.instance))
            if let phone = discovery.devices.first(where: {
                Self.isPhone($0, at: host, seenServices: seenServices, pairedSerial: pairedSerial)
            }) {
                phase = .connected(phone)
                return
            }
            let elapsed = now() - start
            guard elapsed < Self.connectDeadline else { break }
            let addresses = elapsed >= Self.autoConnectWindow ? services.map(\.address) : []
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
    private static func isPhone(_ device: PhysicalDevice, at host: String, seenServices: Set<String>, pairedSerial: String?) -> Bool {
        guard device.isReady, device.isNetwork else { return false }
        if ADBWireless.address(device.serial) != nil { return ADBWireless.host(of: device.serial) == host }
        guard let instance = device.serial.components(separatedBy: "._").first else { return false }
        if seenServices.contains(instance) { return true }
        guard let pairedSerial else { return false }
        return ADBMDNSService(instance: instance, kind: .connect, address: "").deviceName == pairedSerial
    }
}
