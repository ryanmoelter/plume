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
        #expect(ADBWireless.parsePair("Failed: Unable to start pairing client.\n") == .failed(ADBWireless.unreachablePairingService))
        #expect(ADBWireless.parsePair("error: protocol fault (couldn't read status message): Undefined error: 0\n") == .failed(ADBWireless.unreachablePairingService))
        #expect(ADBWireless.parsePair("Failed: Wrong password or connection was dropped.\n") == .failed("Wrong password or connection was dropped."))
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

    /// `getprop ro.serialno` output: the value, or an empty line on a device that doesn't set it.
    @Test func serialNumber() {
        #expect(ADBWireless.parseSerialNumber("53221FDKD0008F\r\n") == "53221FDKD0008F")
        #expect(ADBWireless.parseSerialNumber("\n") == "")
        #expect(ADBWireless.parseSerialNumber("unknown\n") == "unknown")
        #expect(ADBWireless.parseSerialNumber("error: device offline\n") == nil)
        #expect(ADBWireless.parseSerialNumber("") == "")
    }

    @Test func pairingServiceNames() {
        let code = ADBMDNSService(instance: "adb-2B021FDH200A2K-OkOQKV", kind: .pairing, address: "192.168.1.20:37123")
        #expect(code.deviceName == "2B021FDH200A2K")
        #expect(code.isCodePairing)
        let qr = ADBMDNSService(instance: "studio-x1y2", kind: .pairing, address: "192.168.1.20:37123")
        #expect(qr.deviceName == "studio-x1y2")
        #expect(!qr.isCodePairing)
        #expect(!ADBMDNSService(instance: "plume-ab12", kind: .pairing, address: "192.168.1.20:1").isCodePairing)
        #expect(!ADBMDNSService(instance: "adb-X-y", kind: .connect, address: "192.168.1.20:1").isCodePairing)
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
        #expect(discovery.identifier(forSerial: wifi.serial) == "wifi:2B021FDH200A2K")
        #expect(discovery.identifier(forSerial: usb.serial) == "R58M123456A")
    }

    @Test func aWifiDeviceWhoseSerialNumberIsUnknownKeepsItsAdbSerial() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let discovery = discovery([wifi], serials: [:])
        await discovery.refresh()
        #expect(discovery.identifier(forSerial: wifi.serial) == "192.168.1.20:41234")
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

    @Test func aFailedSerialNumberReadIsRetriedOnlyAfterTheBackoff() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let reads = SerialReadCounter()
        let time = ManualTime()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: [wifi]) },
            serialNumber: { _, _ in
                reads.increment()
                return reads.value >= 2 ? "2B021FDH200A2K" : nil
            },
            now: { time.now }
        )
        await discovery.refresh()
        await discovery.refresh()
        #expect(reads.value == 1)
        #expect(discovery.identifier(forSerial: wifi.serial) == wifi.serial)

        time.advance(PhysicalDeviceDiscovery.serialRetryDelay)
        await discovery.refresh()
        #expect(reads.value == 2)
        #expect(discovery.identifier(forSerial: wifi.serial) == "wifi:2B021FDH200A2K")
    }

    @Test func resolvingRetriesARecentFailureAtOnce() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: [wifi]) },
            serialNumber: { _, _ in
                reads.increment()
                return reads.value >= 2 ? "2B021FDH200A2K" : nil
            }
        )
        await discovery.refresh()
        #expect(await discovery.resolvedIdentifier(forSerial: wifi.serial) == "wifi:2B021FDH200A2K")
        #expect(reads.value == 2)
    }

    @Test func aDroppedRefreshStillWaitsForTheNewerListingsSerialNumbers() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let listGate = Gate()
        let lookupGate = Gate()
        let calls = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in
                calls.increment()
                if calls.value == 1 { await listGate.wait() }
                return ADBListing(adbURL: adb, devices: [wifi])
            },
            serialNumber: { _, _ in
                await lookupGate.wait()
                return "2B021FDH200A2K"
            }
        )
        let older = Task { await discovery.refresh() }
        await waitUntilTrue { calls.value == 1 }
        let newer = Task { await discovery.refresh() }
        await waitUntilTrue { discovery.devices == [wifi] }
        await listGate.open()
        let olderFinished = FinishFlag()
        let watcher = Task {
            await older.value
            olderFinished.set()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!olderFinished.value)
        await lookupGate.open()
        await watcher.value
        #expect(discovery.readySerial(for: "wifi:2B021FDH200A2K") == wifi.serial)
        await newer.value
    }

    @Test func onePhoneListedTwiceIsOneRow() async {
        let usb = PhysicalDevice(serial: "2B021FDH200A2K", state: .ready, model: "Pixel_9")
        let named = PhysicalDevice(serial: "adb-2B021FDH200A2K-OkOQKV._adb-tls-connect._tcp", state: .ready, model: "Pixel_9")
        let addressed = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let other = PhysicalDevice(serial: "192.168.1.30:5555", state: .ready, model: "Pixel_8")
        let discovery = discovery([addressed, named, other, usb], serials: [
            named.serial: "2B021FDH200A2K", addressed.serial: "2B021FDH200A2K", other.serial: "OTHER",
        ])
        await discovery.refresh()
        #expect(discovery.phones(in: discovery.devices) == [usb, other])
        #expect(discovery.phones(in: [addressed, named]) == [named])
    }

    @Test func aUSBTabAndAWifiTabNameTheSamePhone() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let discovery = discovery([wifi], serials: [wifi.serial: "2B021FDH200A2K"])
        await discovery.refresh()
        #expect(discovery.namesSamePhone("2B021FDH200A2K", "wifi:2B021FDH200A2K"))
        #expect(discovery.namesSamePhone(wifi.serial, "wifi:2B021FDH200A2K"))
        #expect(!discovery.namesSamePhone("OTHER", "wifi:2B021FDH200A2K"))
        #expect(!discovery.namesSamePhone("192.168.1.99:5555", "wifi:2B021FDH200A2K"))
    }

    @Test func aWifiAddressAdbNoLongerListsStillNamesItsPhone() async {
        let old = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let new = PhysicalDevice(serial: "192.168.1.20:39999", state: .ready, model: nil)
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [old]))
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in "2B021FDH200A2K" })
        await discovery.refresh()
        listing.listing.devices = [new]
        await discovery.refresh()
        #expect(discovery.namesSamePhone(old.serial, "wifi:2B021FDH200A2K"))
        #expect(discovery.readySerial(for: old.serial) == new.serial)
    }

    @Test func aSerialNumberReadForAnUnlistedSerialSurvivesAPublish() async {
        let gate = Gate()
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: []) },
            serialNumber: { _, _ in
                reads.increment()
                await gate.wait()
                return "2B021FDH200A2K"
            }
        )
        await discovery.refresh()
        let resolving = Task { await discovery.resolvedIdentifier(forSerial: "192.168.1.20:41234") }
        await waitUntilTrue { reads.value == 1 }
        await discovery.refresh()
        await gate.open()
        #expect(await resolving.value == "wifi:2B021FDH200A2K")
        #expect(discovery.hardwareSerial(ofIdentifier: "192.168.1.20:41234") == "2B021FDH200A2K")
    }

    @Test func aRetryingRefreshReadsAFailedSerialNumberAtOnce() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: [wifi]) },
            serialNumber: { _, _ in
                reads.increment()
                return reads.value >= 2 ? "2B021FDH200A2K" : nil
            }
        )
        await discovery.refresh()
        await discovery.refreshListing()
        await discovery.resolveListedSerialNumbers(retryingFailedReads: true)
        #expect(reads.value == 2)
        #expect(discovery.readySerial(for: "wifi:2B021FDH200A2K") == wifi.serial)
    }

    @Test func placeholderSerialNumbersNameNoPhone() {
        for placeholder in ["", "  ", "unknown", "UNKNOWN", "0123456789ABCDEF", "0000000000"] {
            #expect(PhysicalDeviceIdentity.isPlaceholderSerial(placeholder), "\(placeholder)")
        }
        #expect(!PhysicalDeviceIdentity.isPlaceholderSerial("2B021FDH200A2K"))
    }

    @Test func phonesReportingAPlaceholderSerialNumberStayApart() async {
        let first = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let second = PhysicalDevice(serial: "192.168.1.30:41234", state: .ready, model: nil)
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: [first, second]) },
            serialNumber: { _, _ in
                reads.increment()
                return "0123456789ABCDEF"
            }
        )
        await discovery.refresh()
        await discovery.refreshListing()
        await discovery.resolveListedSerialNumbers(retryingFailedReads: true)
        #expect(reads.value == 2)
        #expect(discovery.phones(in: discovery.devices) == [first, second])
        #expect(discovery.identifier(forSerial: first.serial) == first.serial)
        #expect(!discovery.namesSamePhone(first.serial, second.serial))
        #expect(discovery.readySerial(for: "wifi:0123456789ABCDEF") == nil)
    }

    @Test func anEmptyOrUnknownSerialNumberIsAPlaceholderNotAFailure() async {
        for reported in ["", "unknown"] {
            let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
            let reads = SerialReadCounter()
            let discovery = PhysicalDeviceDiscovery(
                list: { [adb] in ADBListing(adbURL: adb, devices: [wifi]) },
                serialNumber: { _, _ in
                    reads.increment()
                    return reported
                }
            )
            await discovery.refresh()
            await discovery.refreshListing()
            await discovery.resolveListedSerialNumbers(retryingFailedReads: true)
            #expect(reads.value == 1, "\(reported)")
            #expect(discovery.identifier(forSerial: wifi.serial) == wifi.serial, "\(reported)")
        }
    }

    @Test func theListIsPublishedBeforeSerialNumbersAreRead() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: nil)
        let gate = Gate()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in ADBListing(adbURL: adb, devices: [wifi]) },
            serialNumber: { _, _ in
                await gate.wait()
                return "2B021FDH200A2K"
            }
        )
        let refresh = Task { await discovery.refresh() }
        await waitUntilTrue { discovery.devices == [wifi] }
        #expect(discovery.devices == [wifi])
        #expect(discovery.identifier(forSerial: wifi.serial) == wifi.serial)
        await gate.open()
        await refresh.value
        #expect(discovery.identifier(forSerial: wifi.serial) == "wifi:2B021FDH200A2K")
    }

    @Test func anOlderListingNeverReplacesANewerOne() async {
        let old = PhysicalDevice(serial: "OLD", state: .ready, model: nil)
        let new = PhysicalDevice(serial: "NEW", state: .ready, model: nil)
        let gate = Gate()
        let calls = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(
            list: { [adb] in
                calls.increment()
                if calls.value == 1 {
                    await gate.wait()
                    return ADBListing(adbURL: adb, devices: [old])
                }
                return ADBListing(adbURL: adb, devices: [new])
            },
            serialNumber: { _, _ in nil }
        )
        let first = Task { await discovery.refresh() }
        await waitUntilTrue { calls.value == 1 }
        await discovery.refresh()
        #expect(discovery.devices == [new])
        await gate.open()
        await first.value
        #expect(discovery.devices == [new])
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
        mdnsAvailable: Bool = true,
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
            idleSleep: { _ in },
            mdnsAvailable: { _ in mdnsAvailable }
        )
    }

    @Test func pickingAWifiDeviceBeforeItsSerialNumberIsReadStillPersistsIt() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in "2B021FDH200A2K" })
        var connected: [String] = []
        let session = session(target: nil, discovery: discovery) { connected.append($0) }
        var reported: [DeviceTarget?] = []
        session.onDeviceChange = { target, _ in reported.append(target) }
        session.attach(wifi)
        await waitUntilTrue { !connected.isEmpty }
        #expect(reported == [.physical(serial: "wifi:2B021FDH200A2K")])
        #expect(connected == [wifi.serial])
    }

    @Test func aMissingWifiPhoneWithoutMDNSSaysAdbWontReconnectIt() async {
        let listing = ListingBox(ADBListing(adbURL: adb, devices: []))
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery(listing), mdnsAvailable: false) { _ in }
        session.start()
        await waitUntilTrue { session.state == .notRunning }
        #expect(session.state == .notRunning)
        #expect(!session.wifiReconnectsByItself)
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
        await waitUntilTrue { connected == ["192.168.1.20:41234"] }
        #expect(reported == [.physical(serial: "wifi:2B021FDH200A2K")])
        #expect(session.isWifi)
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

    @Test func showingTheSamePhoneOverWifiLooksForItAgain() async {
        let listing = ListingBox(ADBListing(adbURL: adb, devices: []))
        var connected: [String] = []
        let session = session(target: .physical(serial: "2B021FDH200A2K"), discovery: discovery(listing)) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .notRunning }
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        listing.listing.devices = [wifi]
        session.point(at: .physical(serial: "wifi:2B021FDH200A2K"), displayName: "Pixel 9")
        await waitUntilTrue { session.state == .connected }
        #expect(connected == [wifi.serial])
        #expect(session.target == .physical(serial: "2B021FDH200A2K"))
        withExtendedLifetime(sink) {}
    }

    @Test func aTabSavedUnderAnAddressSwitchesToTheSerialNumberOnceRead() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        let session = session(target: .physical(serial: wifi.serial), discovery: discovery(listing)) { _ in }
        var reported: [DeviceTarget?] = []
        session.onDeviceChange = { target, _ in reported.append(target) }
        session.start()
        await waitUntilTrue { session.state == .suspended }
        #expect(reported == [.physical(serial: "wifi:2B021FDH200A2K")])
        #expect(session.target == .physical(serial: "wifi:2B021FDH200A2K"))
    }

    @Test func aTabSavedUnderAnAddressUpgradesWhenItsPhoneIsOnUSB() async {
        let old = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let usb = PhysicalDevice(serial: "2B021FDH200A2K", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [old]))
        let discovery = discovery(listing)
        await discovery.refresh()
        listing.listing.devices = [usb]
        await discovery.refresh()
        var connected: [String] = []
        let session = session(target: .physical(serial: old.serial), discovery: discovery) { connected.append($0) }
        var reported: [DeviceTarget?] = []
        session.onDeviceChange = { target, _ in reported.append(target) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .connected }
        #expect(connected == [usb.serial])
        #expect(reported == [.physical(serial: "wifi:2B021FDH200A2K")])
        #expect(session.target == .physical(serial: "wifi:2B021FDH200A2K"))
        withExtendedLifetime(sink) {}
    }

    @Test func aSuspendedWifiTabLooksForItsPhoneAgainWhenShown() async {
        let first = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let moved = PhysicalDevice(serial: "192.168.1.20:39999", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [first]))
        var connected: [String] = []
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery(listing)) { connected.append($0) }
        session.start()
        await waitUntilTrue { session.state == .suspended }
        listing.listing.devices = [moved]
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        await waitUntilTrue { session.state == .connected }
        #expect(connected == [moved.serial])
        withExtendedLifetime(sink) {}
    }

    @Test func aPausedWifiTabLooksForItsPhoneAgainOnResume() async {
        let first = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let moved = PhysicalDevice(serial: "192.168.1.20:39999", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [first]))
        var connected: [String] = []
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery(listing)) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .connected }
        session.pauseStreaming()
        #expect(session.state == .streamingPaused)
        listing.listing.devices = [moved]
        session.resumeStreaming()
        await waitUntilTrue { session.state == .connected && connected.count == 2 }
        #expect(connected == [first.serial, moved.serial])
        withExtendedLifetime(sink) {}
    }

    @Test func aWifiTabFindsItsPhoneWhileAFailedReadWaitsOutItsBackoff() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in
            reads.increment()
            return reads.value >= 2 ? "2B021FDH200A2K" : nil
        })
        await discovery.refresh()
        var connected: [String] = []
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .connected || session.state == .notRunning }
        #expect(session.state == .connected)
        #expect(connected == [wifi.serial])
        withExtendedLifetime(sink) {}
    }

    @Test func aPickCancelledWhileReadingTheSerialNumberLeavesNoDevice() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi]))
        let gate = Gate()
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in
            reads.increment()
            await gate.wait()
            return "2B021FDH200A2K"
        })
        var connected: [String] = []
        let session = session(target: nil, discovery: discovery) { connected.append($0) }
        session.attach(wifi)
        await waitUntilTrue { reads.value == 1 }
        #expect(session.state == .locating)
        session.close()
        await gate.open()
        await waitUntilTrue { session.state == .needsDevice }
        #expect(session.state == .needsDevice)
        #expect(session.target == nil)
        #expect(connected.isEmpty)
    }

    @Test func aPickYieldsToADeviceChosenWhileItReadsTheSerialNumber() async {
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let usb = PhysicalDevice(serial: "R58M123456A", state: .ready, model: "Galaxy")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi, usb]))
        let gate = Gate()
        let reads = SerialReadCounter()
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in
            reads.increment()
            await gate.wait()
            return "2B021FDH200A2K"
        })
        var connected: [String] = []
        let session = session(target: nil, discovery: discovery) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.attach(wifi)
        await waitUntilTrue { reads.value == 1 }
        session.point(at: .physical(serial: usb.serial), displayName: "Galaxy")
        await gate.open()
        await waitUntilTrue { session.state == .connected }
        #expect(session.target == .physical(serial: usb.serial))
        #expect(connected == [usb.serial])
        withExtendedLifetime(sink) {}
    }

    @Test func aUSBTabConnectsWithoutWaitingForWifiSerialNumbers() async {
        let usb = PhysicalDevice(serial: "R58M123456A", state: .ready, model: "Galaxy")
        let wifi = PhysicalDevice(serial: "192.168.1.20:41234", state: .ready, model: "Pixel_9")
        let listing = ListingBox(ADBListing(adbURL: adb, devices: [wifi, usb]))
        let gate = Gate()
        let discovery = PhysicalDeviceDiscovery(list: { listing.list() }, serialNumber: { _, _ in
            await gate.wait()
            return "2B021FDH200A2K"
        })
        var connected: [String] = []
        let session = session(target: .physical(serial: usb.serial), discovery: discovery) { connected.append($0) }
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntilTrue { session.state == .connected }
        #expect(session.state == .connected)
        #expect(connected == [usb.serial])
        await gate.open()
        withExtendedLifetime(sink) {}
    }

    @Test func aPhysicalTabWithoutAdbSaysSo() async {
        let discovery = PhysicalDeviceDiscovery(list: { ADBListing(adbURL: nil, devices: []) }, serialNumber: { _, _ in nil })
        let session = session(target: .physical(serial: "wifi:2B021FDH200A2K"), discovery: discovery) { _ in }
        session.start()
        await waitUntilTrue { session.state == .notRunning }
        #expect(session.state == .notRunning)
        #expect(!session.adbFound)
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

/// Holds every waiter until opened.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private nonisolated final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant += duration } }
}

private nonisolated final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}

private nonisolated final class SerialReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
