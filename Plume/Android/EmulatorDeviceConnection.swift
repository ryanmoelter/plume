import CoreGraphics
import EmulatorControl
import Foundation

/// A running emulator over its gRPC control service.
nonisolated final class EmulatorDeviceConnection: DeviceConnecting {
    private let connection: EmulatorConnection

    init(emulator: RunningEmulator) {
        connection = EmulatorConnection(endpoint: EmulatorEndpoint(port: emulator.grpcPort, token: emulator.grpcToken))
    }

    func connect() async throws -> DeviceConnectionInfo {
        DeviceConnectionInfo(deviceSize: try await connection.status().displaySize)
    }

    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<DeviceFrame, Error> {
        .mapping(connection.frames(maxPixelSize: maxPixelSize, useSharedMemory: true)) { frame in
            DeviceFrame(contents: .image(frame.image), pixelSize: frame.pixelSize, rotation: DeviceRotation(frame.rotation), deviceSize: nil)
        }
    }

    func send(_ input: DeviceInput) {
        switch input {
        case .touch(let phase, let location):
            let point = TouchPoint(
                x: Int32(location.point.x), y: Int32(location.point.y), identifier: 0, pressure: phase == .up ? 0 : 1
            )
            connection.send(.touch([point]))
        case .scroll(let location, let dx, let dy):
            if let location {
                connection.send(.mouse(x: Int32(location.point.x), y: Int32(location.point.y), buttons: 0))
            }
            connection.send(.wheel(dx: dx, dy: dy))
        case .emulatorKey(let key):
            connection.send(.key(key.input))
        case .androidKey:
            break
        }
    }

    func press(_ button: DeviceButton, phase: DeviceKeyPhase) {
        connection.press(button.hardwareButton, phase: phase.keyPhase)
    }

    func rotate(to rotation: DeviceRotation) async throws {
        try await connection.rotate(to: rotation.emulatorRotation)
    }

    func shutDown() async throws {
        try await connection.shutDown()
    }

    func close() async {
        await connection.close()
    }

    /// The gRPC channel dies with the app, and the emulator is meant to outlive it.
    func terminate() {}
}

private extension DeviceButton {
    nonisolated var hardwareButton: HardwareButton {
        switch self {
        case .back: .back
        case .home: .home
        case .overview: .overview
        case .power: .power
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        }
    }
}

private extension DeviceKey {
    nonisolated var input: KeyInput {
        switch self {
        case .mac(let keyCode, let phase): .mac(keyCode: keyCode, phase: phase.keyPhase)
        case .evdev(let keyCode, let phase): .evdev(keyCode: keyCode, phase: phase.keyPhase)
        }
    }
}

private extension DeviceKeyPhase {
    nonisolated var keyPhase: KeyPhase {
        switch self {
        case .down: .down
        case .up: .up
        }
    }
}
