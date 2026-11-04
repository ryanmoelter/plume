import Foundation
import Testing
@testable import Plume

private let adbURL = URL(fileURLWithPath: "/sdk/platform-tools/adb")
private let phoneAddress = "192.168.1.20:41234"

/// Scripts adb: what mDNS shows, how pair and connect answer, and what each does to `adb devices`.
private nonisolated final class FakeWireless: ADBWirelessRunning, @unchecked Sendable {
    private let lock = NSLock()
    let listing: ListingBox
    private var _mdns = true
    private var _services: [ADBMDNSService] = []
    private var _servicesCalls = 0
    private var _pairs: [(address: String, code: String)] = []
    private var _connects: [String] = []
    private var _pairOutcome = ADBCommandOutcome.succeeded
    private var _connectOutcome = ADBCommandOutcome.succeeded
    /// Listed after a successful pair, as adb's mDNS auto-connect would.
    private var _autoConnected: PhysicalDevice?
    /// Listed after a successful connect.
    private var _connected: PhysicalDevice?

    init(devices: [PhysicalDevice] = []) {
        listing = ListingBox(ADBListing(adbURL: adbURL, devices: devices))
    }

    var mdns: Bool { get { lock.withLock { _mdns } } set { lock.withLock { _mdns = newValue } } }
    var servicesShown: [ADBMDNSService] { get { lock.withLock { _services } } set { lock.withLock { _services = newValue } } }
    var servicesCalls: Int { lock.withLock { _servicesCalls } }
    var pairs: [(address: String, code: String)] { lock.withLock { _pairs } }
    var connects: [String] { lock.withLock { _connects } }
    var pairOutcome: ADBCommandOutcome { get { lock.withLock { _pairOutcome } } set { lock.withLock { _pairOutcome = newValue } } }
    var autoConnected: PhysicalDevice? { get { lock.withLock { _autoConnected } } set { lock.withLock { _autoConnected = newValue } } }
    var connected: PhysicalDevice? { get { lock.withLock { _connected } } set { lock.withLock { _connected = newValue } } }
    var connectOutcome: ADBCommandOutcome { get { lock.withLock { _connectOutcome } } set { lock.withLock { _connectOutcome = newValue } } }

    func mdnsAvailable() async -> Bool { mdns }

    func services() async -> [ADBMDNSService] {
        lock.withLock {
            _servicesCalls += 1
            return _services
        }
    }

    func pair(address: String, code: String) async -> ADBCommandOutcome {
        let (outcome, device) = lock.withLock {
            _pairs.append((address, code))
            return (_pairOutcome, _autoConnected)
        }
        if outcome == .succeeded, let device { listing.listing.devices.append(device) }
        return outcome
    }

    func connect(address: String) async -> ADBCommandOutcome {
        let (outcome, device) = lock.withLock {
            _connects.append(address)
            return (_connectOutcome, _connected)
        }
        if outcome == .succeeded, let device { listing.listing.devices.append(device) }
        return outcome
    }
}

/// Time that passes only when the coordinator sleeps.
private nonisolated final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant += duration } }
}

@MainActor
private func makePairing(_ fake: FakeWireless, time: FakeTime = FakeTime()) -> WirelessPairing {
    let listing = fake.listing
    return WirelessPairing(
        adb: fake,
        discovery: PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in nil }),
        sleep: { duration in
            time.advance(duration)
            await Task.yield()
        },
        now: { time.now }
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func failure(of pairing: WirelessPairing) async -> String? {
    await waitUntil { if case .failed = pairing.phase { true } else { false } }
    guard case .failed(let message) = pairing.phase else { return nil }
    return message
}

private let mdnsPhone = PhysicalDevice(serial: "adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp", state: .ready, model: "Pixel_9")
private let phoneConnectService = ADBMDNSService(instance: "adb-2B021FDH200A2K-OkOQKV", kind: .connect, address: phoneAddress)

/// Covers both pairing flows end to end against scripted adb: finding the scanned QR service,
/// adb's mDNS auto-connect, Plume's own `adb connect` fallback, and the readable failures.
@MainActor
struct WirelessPairingTests {
    @Test func aScannedQRCodePairsWithItsPasswordAndConnects() async {
        let fake = FakeWireless()
        fake.autoConnected = mdnsPhone
        let pairing = makePairing(fake)
        pairing.startQRCode()
        #expect(pairing.phase == .waitingForScan)
        fake.servicesShown = [
            ADBMDNSService(instance: "plume-someoneelse", kind: .pairing, address: "192.168.1.30:37000"),
            ADBMDNSService(instance: pairing.qr.name, kind: .pairing, address: "192.168.1.20:37123"),
            phoneConnectService,
        ]
        await waitUntil { pairing.phase == .connected(mdnsPhone) }
        #expect(pairing.phase == .connected(mdnsPhone))
        #expect(fake.pairs.map(\.address) == ["192.168.1.20:37123"])
        #expect(fake.pairs.map(\.code) == [pairing.qr.password])
        #expect(fake.connects.isEmpty)
    }

    @Test func anotherPhonesPairingServiceIsIgnored() async {
        let fake = FakeWireless()
        fake.servicesShown = [ADBMDNSService(instance: "studio-abc", kind: .pairing, address: "192.168.1.30:37000")]
        let pairing = makePairing(fake)
        pairing.startQRCode()
        await waitUntil { fake.servicesCalls >= 5 }
        #expect(pairing.phase == .waitingForScan)
        #expect(fake.pairs.isEmpty)
        pairing.cancel()
        #expect(pairing.phase == .idle)
    }

    @Test func withoutMDNSTheQRCodeSaysSo() async {
        let fake = FakeWireless()
        fake.mdns = false
        let pairing = makePairing(fake)
        pairing.startQRCode()
        await waitUntil { pairing.phase == .mdnsUnavailable }
        #expect(pairing.phase == .mdnsUnavailable)
    }

    @Test func eachQRCodeIsFresh() {
        let pairing = makePairing(FakeWireless())
        pairing.startQRCode()
        let first = pairing.qr
        pairing.startQRCode()
        #expect(pairing.qr != first)
        pairing.cancel()
    }

    @Test func aPairingCodeNeedsAnAddressAndDigits() {
        let pairing = makePairing(FakeWireless())
        pairing.pair(address: "192.168.1.20", code: "123456")
        guard case .failed = pairing.phase else { Issue.record("expected a failure, got \(pairing.phase)"); return }
        pairing.pair(address: "192.168.1.20:37123", code: "12a456")
        guard case .failed = pairing.phase else { Issue.record("expected a failure, got \(pairing.phase)"); return }
    }

    @Test func aRejectedPairShowsAdbsReason() async {
        let fake = FakeWireless()
        fake.pairOutcome = .failed("Wrong password or connection was dropped.")
        let pairing = makePairing(fake)
        pairing.pair(address: " 192.168.1.20:37123 ", code: "123456")
        #expect(await failure(of: pairing) == "Wrong password or connection was dropped.")
        #expect(fake.pairs.map(\.address) == ["192.168.1.20:37123"])
    }

    @Test func withoutAutoConnectPlumeConnectsToThePhonesConnectService() async {
        let fake = FakeWireless()
        let phone = PhysicalDevice(serial: phoneAddress, state: .ready, model: "Pixel_9")
        fake.connected = phone
        fake.servicesShown = [
            ADBMDNSService(instance: "adb-OTHER-x", kind: .connect, address: "192.168.1.99:40000"),
            phoneConnectService,
        ]
        let pairing = makePairing(fake)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        await waitUntil { pairing.phase == .connected(phone) }
        #expect(pairing.phase == .connected(phone))
        #expect(fake.connects == [phoneAddress])
    }

    @Test func aNewWifiDeviceOnAnotherHostIsNotThePairedPhone() async {
        let fake = FakeWireless()
        fake.autoConnected = PhysicalDevice(serial: "192.168.1.50:5555", state: .ready, model: nil)
        fake.servicesShown = [ADBMDNSService(instance: "adb-OTHER-x", kind: .connect, address: "192.168.1.50:5555")]
        let pairing = makePairing(fake)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        let message = await failure(of: pairing)
        #expect(message?.hasPrefix("Paired, but the device didn't connect.") == true)
        #expect(fake.connects.isEmpty)
    }

    @Test func aPhoneAlreadyConnectedUnderItsMDNSNameCountsWhenPairedAgain() async {
        let fake = FakeWireless(devices: [mdnsPhone])
        fake.servicesShown = [phoneConnectService]
        let pairing = makePairing(fake)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        await waitUntil { pairing.phase == .connected(mdnsPhone) }
        #expect(pairing.phase == .connected(mdnsPhone))
        #expect(fake.connects.isEmpty)
    }

    @Test func aFailedConnectIsTriedOnceAndTheWaitEndsOnTime() async {
        let fake = FakeWireless()
        fake.connectOutcome = .failed("Failed to connect to '192.168.1.20:41234': Connection refused")
        fake.servicesShown = [phoneConnectService]
        let time = FakeTime()
        let started = time.now
        let pairing = makePairing(fake, time: time)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        let message = await failure(of: pairing)
        #expect(message?.contains("Connection refused") == true)
        #expect(fake.connects == [phoneAddress])
        #expect(time.now - started <= WirelessPairing.connectDeadline + WirelessPairing.pollInterval)
    }
}
