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

@MainActor
private func makePairing(_ fake: FakeWireless) -> WirelessPairing {
    let listing = fake.listing
    return WirelessPairing(
        adb: fake,
        discovery: PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in nil }),
        sleep: { _ in await Task.yield() }
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Covers both pairing flows end to end against scripted adb: finding the scanned QR service,
/// adb's mDNS auto-connect, Plume's own `adb connect` fallback, and the readable failures.
@MainActor
struct WirelessPairingTests {
    @Test func aScannedQRCodePairsWithItsPasswordAndConnects() async {
        let fake = FakeWireless()
        let phone = PhysicalDevice(serial: "adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp", state: .ready, model: "Pixel_9")
        fake.autoConnected = phone
        let pairing = makePairing(fake)
        pairing.startQRCode()
        #expect(pairing.phase == .waitingForScan)
        fake.servicesShown = [
            ADBMDNSService(instance: "plume-someoneelse", kind: .pairing, address: "192.168.1.30:37000"),
            ADBMDNSService(instance: pairing.qr.name, kind: .pairing, address: "192.168.1.20:37123"),
        ]
        await waitUntil { pairing.phase == .connected(phone) }
        #expect(pairing.phase == .connected(phone))
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
        fake.pairOutcome = .failed("Unable to start pairing client.")
        let pairing = makePairing(fake)
        pairing.pair(address: " 192.168.1.20:37123 ", code: "123456")
        await waitUntil { pairing.phase == .failed("Unable to start pairing client.") }
        #expect(pairing.phase == .failed("Unable to start pairing client."))
        #expect(fake.pairs.map(\.address) == ["192.168.1.20:37123"])
    }

    @Test func withoutAutoConnectPlumeConnectsToThePhonesConnectService() async {
        let fake = FakeWireless()
        let phone = PhysicalDevice(serial: phoneAddress, state: .ready, model: "Pixel_9")
        fake.connected = phone
        fake.servicesShown = [
            ADBMDNSService(instance: "adb-OTHER-x", kind: .connect, address: "192.168.1.99:40000"),
            ADBMDNSService(instance: "adb-2B021FDH200A2K-OkOQKV", kind: .connect, address: phoneAddress),
        ]
        let pairing = makePairing(fake)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        await waitUntil { pairing.phase == .connected(phone) }
        #expect(pairing.phase == .connected(phone))
        #expect(fake.connects == [phoneAddress])
    }

    @Test func aPhoneAlreadyListedBeforePairingDoesNotCount() async {
        let usb = PhysicalDevice(serial: "192.168.1.50:5555", state: .ready, model: nil)
        let fake = FakeWireless(devices: [usb])
        let pairing = makePairing(fake)
        pairing.pair(address: "192.168.1.20:37123", code: "123456")
        await waitUntil { if case .failed = pairing.phase { true } else { false } }
        guard case .failed(let message) = pairing.phase else {
            Issue.record("expected a failure, got \(pairing.phase)")
            return
        }
        #expect(message.hasPrefix("Paired, but the device didn't connect."))
        #expect(fake.connects.isEmpty)
    }
}
