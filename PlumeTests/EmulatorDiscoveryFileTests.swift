import Foundation
import Testing
@testable import Plume

struct EmulatorDiscoveryFileTests {
    static let sample = """
    emulator.build=15917651
    avd.id=Pixel_Tablet
    port.serial=5554
    port.adb=5555
    avd.name=Pixel Tablet
    emulator.version=37.1.11.0
    avd.dir=/Users/me/.android/avd/Pixel_Tablet.avd
    cmdline="/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64" "@Pixel_Tablet"
    grpc.token=bO47ZuMm==
    grpc.port=8554
    """

    @Test func parsesRealKeySet() throws {
        let emulator = try #require(EmulatorDiscoveryFile.parse(text: Self.sample, fileName: "pid_92577.ini"))
        #expect(emulator.pid == 92577)
        #expect(emulator.avdID == "Pixel_Tablet")
        #expect(emulator.avdName == "Pixel Tablet")
        #expect(emulator.avdDirectory?.path == "/Users/me/.android/avd/Pixel_Tablet.avd")
        #expect(emulator.grpcPort == 8554)
        #expect(emulator.adbPort == 5555)
        #expect(emulator.serialPort == 5554)
        #expect(emulator.adbSerial == "emulator-5554")
        #expect(emulator.version == "37.1.11.0")
    }

    @Test func splitsOnFirstEqualsOnly() throws {
        let emulator = try #require(EmulatorDiscoveryFile.parse(text: Self.sample, fileName: "pid_1.ini"))
        #expect(emulator.grpcToken == "bO47ZuMm==")
    }

    @Test func toleratesCRLF() throws {
        let text = Self.sample.replacingOccurrences(of: "\n", with: "\r\n")
        let emulator = try #require(EmulatorDiscoveryFile.parse(text: text, fileName: "pid_1.ini"))
        #expect(emulator.grpcPort == 8554)
        #expect(emulator.grpcToken == "bO47ZuMm==")
    }

    @Test func missingGrpcPortIsNil() {
        let text = Self.sample.replacingOccurrences(of: "grpc.port=8554", with: "")
        #expect(EmulatorDiscoveryFile.parse(text: text, fileName: "pid_1.ini") == nil)
    }

    @Test func missingTokenIsNilToken() throws {
        let text = Self.sample.replacingOccurrences(of: "grpc.token=bO47ZuMm==", with: "")
        let emulator = try #require(EmulatorDiscoveryFile.parse(text: text, fileName: "pid_1.ini"))
        #expect(emulator.grpcToken == nil)
    }

    @Test(arguments: ["92577.ini", "pid_.ini", "pid_abc.ini", "pid_1.txt", "jwks"])
    func rejectsOtherFileNames(name: String) {
        #expect(EmulatorDiscoveryFile.parse(text: Self.sample, fileName: name) == nil)
    }

    @Test func noSerialPortMeansNoSerial() throws {
        let text = Self.sample.replacingOccurrences(of: "port.serial=5554", with: "")
        let emulator = try #require(EmulatorDiscoveryFile.parse(text: text, fileName: "pid_1.ini"))
        #expect(emulator.adbSerial == nil)
    }
}
