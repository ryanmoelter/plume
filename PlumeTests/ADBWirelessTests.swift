import Foundation
import Testing
@testable import Plume

struct ADBWirelessParsingTests {
    @Test func parsesPairingAndConnectServices() {
        let output = """
        List of discovered mdns services
        plume-0a1b2c3d4e\t_adb-tls-pairing._tcp\t192.168.1.20:37123
        adb-2B021FDH200A2K-OkOQKV\t_adb-tls-connect._tcp.\t192.168.1.20:41234
        adb-OTHER-xyz  _adb._tcp  10.0.0.4:5555
        """
        let services = ADBWireless.parseServices(output)
        #expect(services == [
            ADBMDNSService(instance: "plume-0a1b2c3d4e", kind: .pairing, address: "192.168.1.20:37123"),
            ADBMDNSService(instance: "adb-2B021FDH200A2K-OkOQKV", kind: .connect, address: "192.168.1.20:41234"),
            ADBMDNSService(instance: "adb-OTHER-xyz", kind: .other("_adb._tcp"), address: "10.0.0.4:5555"),
        ])
        #expect(services[1].host == "192.168.1.20")
    }

    @Test func servicesWithoutAnAddressAreSkipped() {
        #expect(ADBWireless.parseServices("List of discovered mdns services\n\nadb-x\t_adb-tls-connect._tcp\n").isEmpty)
        #expect(ADBWireless.parseServices("").isEmpty)
    }

    @Test func mdnsCheck() {
        #expect(ADBWireless.parseMDNSCheck("mdns daemon version [Openscreen discovery 0.0.0]\n"))
        #expect(!ADBWireless.parseMDNSCheck("ERROR: mdns daemon unavailable\n"))
        #expect(!ADBWireless.parseMDNSCheck(""))
    }

    @Test func pairOutcome() {
        #expect(ADBWireless.parsePair("Successfully paired to 192.168.1.20:37123 [guid=adb-2B021FDH200A2K-OkOQKV]\n") == .succeeded)
        #expect(ADBWireless.parsePair("Failed: Unable to start pairing client.\n") == .failed("Unable to start pairing client."))
        #expect(ADBWireless.parsePair("\n") == .failed("Pairing failed."))
    }

    @Test func connectOutcomeReadsTheTextNotTheExitStatus() {
        #expect(ADBWireless.parseConnect("connected to 192.168.1.20:41234\n") == .succeeded)
        #expect(ADBWireless.parseConnect("already connected to 192.168.1.20:41234\n") == .succeeded)
        #expect(
            ADBWireless.parseConnect("failed to connect to '192.168.1.20:41234': Connection refused\n")
                == .failed("Failed to connect to '192.168.1.20:41234': Connection refused")
        )
        #expect(ADBWireless.parseConnect("cannot connect to 192.168.1.20:41234: No route to host\n") != .succeeded)
    }

    @Test func serialNumber() {
        #expect(ADBWireless.parseSerialNumber("2B021FDH200A2K\n") == "2B021FDH200A2K")
        #expect(ADBWireless.parseSerialNumber("unknown\n") == nil)
        #expect(ADBWireless.parseSerialNumber("error: device offline\n") == nil)
        #expect(ADBWireless.parseSerialNumber("") == nil)
    }

    @Test func address() {
        #expect(ADBWireless.address(" 192.168.1.20:37123 ") == "192.168.1.20:37123")
        #expect(ADBWireless.address("192.168.1.20") == nil)
        #expect(ADBWireless.address("192.168.1.20:port") == nil)
        #expect(ADBWireless.address(":5555") == nil)
        #expect(ADBWireless.address("192.168.1.20:70000") == nil)
    }

    @Test func qrPayloadNamesTheServiceAndPassword() {
        let qr = ADBPairingQR(name: "plume-0a1b2c3d4e", password: "00112233aabb")
        #expect(qr.payload == "WIFI:T:ADB;S:plume-0a1b2c3d4e;P:00112233aabb;;")
    }

    @Test func randomQRCodesDifferAndNeedNoEscaping() {
        let first = ADBPairingQR.random()
        let second = ADBPairingQR.random()
        #expect(first != second)
        #expect(first.name.hasPrefix("plume-"))
        let hex = Set("0123456789abcdef")
        #expect(first.password.allSatisfy { hex.contains($0) })
        #expect(first.name.dropFirst("plume-".count).allSatisfy { hex.contains($0) })
    }

    @Test func networkSerials() {
        func isNetwork(_ serial: String) -> Bool { PhysicalDevice(serial: serial, state: .ready, model: nil).isNetwork }
        #expect(isNetwork("192.168.1.20:41234"))
        #expect(isNetwork("adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp"))
        #expect(!isNetwork("2B021FDH200A2K"))
        #expect(!isNetwork("localhost:40123"))
        #expect(!isNetwork("emulator-5554"))
    }

    @Test func wifiIdentity() {
        let identifier = PhysicalDeviceIdentity.wifi(hardwareSerial: "2B021FDH200A2K")
        #expect(identifier == "wifi:2B021FDH200A2K")
        #expect(PhysicalDeviceIdentity.isWifi(identifier))
        #expect(PhysicalDeviceIdentity.hardwareSerial(of: identifier) == "2B021FDH200A2K")
        #expect(PhysicalDeviceIdentity.hardwareSerial(of: "R58M123456A") == "R58M123456A")
        #expect(DeviceTarget(platform: .androidPhysical, identifier: identifier) == .physical(serial: identifier))
    }
}

@MainActor
struct PhysicalDeviceIdentityTests {
    private let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")

    private func discovery(_ devices: [PhysicalDevice], serials: [String: String]) -> PhysicalDeviceDiscovery {
        let adb = adb
        return PhysicalDeviceDiscovery(
            list: { ADBListing(adbURL: adb, devices: devices) },
            serialNumber: { _, serial in serials[serial] }
        )
    }

    @Test func aWifiDeviceIsNamedByItsSerialNumber() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let usb = PhysicalDevice(serial: "R58M123456A", state: .ready, model: nil)
        let discovery = discovery([wifi, usb], serials: ["192.168.1.20:41234": "2B021FDH200A2K"])
        await discovery.refresh()
        #expect(discovery.identifier(for: wifi) == "wifi:2B021FDH200A2K")
        #expect(discovery.identifier(for: usb) == "R58M123456A")
    }

    @Test func aWifiDeviceWhoseSerialNumberIsUnknownKeepsItsAdbSerial() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let discovery = discovery([wifi], serials: [:])
        await discovery.refresh()
        #expect(discovery.identifier(for: wifi) == "192.168.1.20:41234")
    }

    @Test func aWifiIdentifierFindsTheDeviceAtANewAddress() async {
        let reconnected = PhysicalDevice(serial: "adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp", state: .ready, model: nil)
        let discovery = discovery([reconnected], serials: [reconnected.serial: "2B021FDH200A2K"])
        await discovery.refresh()
        #expect(discovery.readySerial(for: "wifi:2B021FDH200A2K") == reconnected.serial)
        #expect(discovery.readySerial(for: "wifi:SOMEONEELSE") == nil)
    }

    @Test func aWifiIdentifierPrefersWifiAndFallsBackToUSB() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let usb = PhysicalDevice(serial: "2B021FDH200A2K", state: .ready, model: nil)
        let both = discovery([usb, wifi], serials: [wifi.serial: "2B021FDH200A2K"])
        await both.refresh()
        #expect(both.readySerial(for: "wifi:2B021FDH200A2K") == wifi.serial)
        #expect(both.readySerial(for: "2B021FDH200A2K") == usb.serial)

        let usbOnly = discovery([usb], serials: [:])
        await usbOnly.refresh()
        #expect(usbOnly.readySerial(for: "wifi:2B021FDH200A2K") == usb.serial)
    }

    @Test func aDeviceThatIsNotReadyIsNotResolved() async {
        let offline = PhysicalDevice(serial: "192.168.1.20:41234", state: .offline, model: nil)
        let discovery = discovery([offline], serials: [offline.serial: "2B021FDH200A2K"])
        await discovery.refresh()
        #expect(discovery.readySerial(for: "wifi:2B021FDH200A2K") == nil)
        #expect(discovery.readySerial(for: offline.serial) == nil)
    }

    @Test func serialNumbersAreReadOncePerConnection() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let reads = SerialReadCounter()
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        let discovery = PhysicalDeviceDiscovery(
            list: { listing.list() },
            serialNumber: { _, _ in
                reads.increment()
                return "2B021FDH200A2K"
            }
        )
        await discovery.refresh()
        await discovery.refresh()
        #expect(reads.value == 1)

        listing.listing.devices = []
        await discovery.refresh()
        listing.listing.devices = [wifi]
        await discovery.refresh()
        #expect(reads.value == 2)
    }
}

@MainActor
struct WifiDeviceSessionTests {
    private let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")

    private func discovery(_ listing: ListingBox) -> PhysicalDeviceDiscovery {
        PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in "2B021FDH200A2K" })
    }

    private func session(
        target: DeviceTarget?,
        discovery: PhysicalDeviceDiscovery,
        connectedTo: @escaping (String) -> Void
    ) -> DeviceSession {
        let fake = FakeConnection()
        return DeviceSession(
            tabID: UUID(), target: target, displayName: "Pixel 9",
            discovery: EmulatorDiscovery(directories: [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)]),
            physicalDiscovery: discovery,
            makeConnection: { device in
                if case .physical(let serial, _, _) = device { connectedTo(serial) }
                return fake
            },
            idleSleep: { _ in }
        )
    }

    @Test func pickingAWifiDevicePersistsItsSerialNumber() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        var connected: [String] = []
        let discovery = discovery(listing)
        let session = session(target: nil, discovery: discovery) { connected.append($0) }
        var reported: [DeviceTarget?] = []
        session.onDeviceChange = { target, _ in reported.append(target) }
        await discovery.refresh()
        session.attach(wifi)
        #expect(reported == [.physical(serial: "wifi:2B021FDH200A2K")])
        #expect(session.isWifi)
        await waitUntilTrue { connected == ["192.168.1.20:41234"] }
        #expect(connected == ["192.168.1.20:41234"])
    }

    @Test func aWifiTabReconnectsAtTheDevicesNewAddress() async {
        let moved = PhysicalDevice(serial: "adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [moved]))
        var connected: [String] = []
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery(listing)) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .connected }
        #expect(session.state == .connected)
        #expect(connected == [moved.serial])
    }

    @Test func aWifiTabWhoseDeviceIsGoneIsNotRunning() async {
        let listing = ListingBox(ADBListing(adbURL: adb, devices: []))
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery(listing)) { _ in }
        session.start()
        await waitUntilTrue { session.state == .notRunning }
        #expect(session.state == .notRunning)
        #expect(session.isWifi)
    }
}

@MainActor
private func waitUntilTrue(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private nonisolated final class SerialReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
