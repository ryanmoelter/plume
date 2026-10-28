import Foundation
import Testing
@testable import Plume

struct ADBDeviceListTests {
    @Test func parsesReadyUnauthorizedAndOfflineDevices() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        53221FDKD0008F         device usb:1048576X product:comet model:Pixel_9_Pro_Fold device:comet transport_id:8
        R58M123456A            unauthorized usb:1-1 transport_id:3
        192.168.1.5:5555       offline transport_id:4

        """
        let devices = ADBDeviceList.parse(output)
        #expect(devices.map(\.serial) == ["53221FDKD0008F", "R58M123456A", "192.168.1.5:5555"])
        #expect(devices.map(\.state) == [.ready, .unauthorized, .offline])
        #expect(devices[0].displayName == "Pixel 9 Pro Fold")
        #expect(devices[1].displayName == "R58M123456A")
        #expect(devices[0].isReady)
        #expect(!devices[1].isReady)
    }

    @Test func dropsEmulators() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        ABC                    device model:Pixel_8 transport_id:2
        """
        #expect(ADBDeviceList.parse(output).map(\.serial) == ["ABC"])
    }

    @Test func unknownStateIsKept() {
        let devices = ADBDeviceList.parse("List of devices attached\nXYZ recovery transport_id:5\n")
        #expect(devices.first?.state == .other("recovery"))
    }

    @Test func emptyListHasNoDevices() {
        #expect(ADBDeviceList.parse("List of devices attached\n\n").isEmpty)
        #expect(ADBDeviceList.parse("").isEmpty)
    }
}

@MainActor
struct PhysicalDeviceDiscoveryTests {
    @Test func refreshPublishesTheListing() async {
        let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")
        let device = PhysicalDevice(serial: "S1", state: .ready, model: "Pixel_8")
        let discovery = PhysicalDeviceDiscovery { ADBListing(adbURL: adb, devices: [device]) }
        await discovery.refresh()
        #expect(discovery.devices == [device])
        #expect(discovery.adbURL == adb)
    }
}
