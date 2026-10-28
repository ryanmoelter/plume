import CoreGraphics
import CoreVideo
import Foundation
import ScrcpyControl
import VideoToolbox

/// A physical device mirrored through scrcpy-server. Frames arrive already rotated, and touches are
/// expressed in the current video size, so the session treats every frame as portrait.
nonisolated final class PhysicalDeviceConnection: DeviceConnecting {
    private let connection: ScrcpyConnection?

    init(serial: String, adbURL: URL, jarURL: URL? = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil)) {
        connection = jarURL.map {
            ScrcpyConnection(adbURL: adbURL, serial: serial, jarURL: $0, version: ScrcpyServerVersion.pinned)
        }
    }

    func connect() async throws -> DeviceConnectionInfo {
        guard let connection else { throw DeviceConnectionError(message: "scrcpy-server is missing from the app bundle.") }
        do {
            let (_, size) = try await connection.connect()
            return DeviceConnectionInfo(deviceSize: size)
        } catch {
            throw Self.describe(error)
        }
    }

    /// Native size: the layer scales, so a resize never restarts the stream.
    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<DeviceFrame, Error> {
        guard let connection else { return AsyncThrowingStream { $0.finish() } }
        return .mapping(connection.frames(), mapError: Self.describe) { frame in
            let contents: DeviceFrame.Contents
            if let surface = frame.surface {
                contents = .surface(surface, owner: frame.pixelBuffer)
            } else {
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(frame.pixelBuffer, options: nil, imageOut: &image)
                guard let image else { return nil }
                contents = .image(image)
            }
            return DeviceFrame(contents: contents, pixelSize: frame.pixelSize, rotation: .portrait, deviceSize: frame.videoSize)
        }
    }

    func send(_ input: DeviceInput) {
        guard let connection else { return }
        switch input {
        case .touch(let phase, let location):
            let action: UInt8 = switch phase {
            case .down: Android.MotionAction.down
            case .move: Android.MotionAction.move
            case .up: Android.MotionAction.up
            }
            connection.send(.injectTouch(
                action: action,
                pointerID: ScrcpyPointerID.genericFinger,
                position: ScrcpyPosition(point: location.point, screenSize: location.deviceSize),
                pressure: phase == .up ? 0 : 1,
                actionButton: 0,
                buttons: 0
            ))
        case .scroll(let location, let dx, let dy):
            // scrcpy-server scrolls at a position, so a wheel off the screen goes nowhere.
            guard let location else { return }
            connection.send(.injectScroll(
                position: ScrcpyPosition(point: location.point, screenSize: location.deviceSize),
                hScroll: Float(dx) / Float(WheelAccumulator.unitsPerNotch),
                vScroll: Float(dy) / Float(WheelAccumulator.unitsPerNotch),
                buttons: 0
            ))
        case .androidKey(.key(let phase, let keycode, let metaState)):
            connection.send(.injectKeycode(action: phase.androidAction, keycode: keycode, metaState: metaState))
        case .androidKey(.text(let text)):
            connection.send(.injectText(text))
        case .emulatorKey:
            break
        }
    }

    func press(_ button: DeviceButton, phase: DeviceKeyPhase) {
        guard let connection else { return }
        let keycode: UInt32
        switch button {
        case .back:
            // Wakes a sleeping screen instead of doing nothing.
            connection.send(.backOrScreenOn(action: phase.androidAction))
            return
        case .home: keycode = Android.KeyCode.home
        case .overview: keycode = Android.KeyCode.appSwitch
        case .power: keycode = Android.KeyCode.power
        case .volumeUp: keycode = Android.KeyCode.volumeUp
        case .volumeDown: keycode = Android.KeyCode.volumeDown
        }
        connection.send(.injectKeycode(action: phase.androidAction, keycode: keycode))
    }

    /// scrcpy can only toggle between portrait and landscape, so every request flips the device.
    func rotate(to rotation: DeviceRotation) async throws {
        connection?.send(.rotateDevice)
    }

    /// A physical device is never powered off from Plume.
    func shutDown() async throws {}

    func close() async {
        await connection?.close()
    }

    func terminate() {
        connection?.terminate()
    }

    private static nonisolated func describe(_ error: Error) -> Error {
        if error is LocalizedError || error is CancellationError { return error }
        return DeviceConnectionError(message: String(describing: error))
    }
}

private extension DeviceKeyPhase {
    nonisolated var androidAction: UInt8 {
        switch self {
        case .down: Android.KeyAction.down
        case .up: Android.KeyAction.up
        }
    }
}
