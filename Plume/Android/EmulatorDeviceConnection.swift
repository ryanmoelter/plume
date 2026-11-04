import CoreGraphics
import EmulatorControl
import Foundation
import Synchronization

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
            submit(.input(.touch([point])))
        case .scroll(let location, let dx, let dy):
            if let location {
                submit(.input(.mouse(x: Int32(location.point.x), y: Int32(location.point.y), buttons: 0)))
            }
            submit(.input(.wheel(dx: dx, dy: dy)))
        case .emulatorKey(let key):
            submit(.input(.key(key.input)))
        case .androidKey:
            break
        }
    }

    func press(_ button: DeviceButton, phase: DeviceKeyPhase) {
        submit(.button(button.hardwareButton, phase.keyPhase))
    }

    func paste(text: String) {
        order.withLock { perform($0.paste(text)) }
    }

    private enum OrderedInput: Sendable {
        case input(EmulatorInput)
        case button(HardwareButton, KeyPhase)
    }

    /// setClipboard returns before the guest has the text, and nothing reports when it does.
    private static let clipboardSettleDelay: Duration = .milliseconds(150)

    private let order = Mutex(EmulatorInputOrder<OrderedInput>())

    private func submit(_ input: OrderedInput) {
        order.withLock { perform($0.input(input)) }
    }

    /// Runs under `order`'s lock, so a step released by a finished paste can't be overtaken by new input.
    private func perform(_ steps: [EmulatorInputOrder<OrderedInput>.Step]) {
        for step in steps {
            switch step {
            case .deliver(.input(let input)): connection.send(input)
            case .deliver(.button(let button, let phase)): connection.press(button, phase: phase)
            case .startPaste(let text): startPaste(text)
            }
        }
    }

    private func startPaste(_ text: String) {
        Task {
            do {
                try await connection.setClipboard(text)
                try? await Task.sleep(for: Self.clipboardSettleDelay)
                for key in EmulatorKeyMapper.pasteChord { connection.send(.key(key.input)) }
            } catch {
                EmulatorLog.error("setting the emulator clipboard failed: \(error)")
            }
            order.withLock { perform($0.pasteFinished()) }
        }
    }

    func rotate(to rotation: DeviceRotation) async throws {
        try await connection.rotate(to: rotation.emulatorRotation)
    }

    func autoRotate() async -> Bool? { nil }
    func setAutoRotate(_ enabled: Bool) async -> Bool { false }

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
