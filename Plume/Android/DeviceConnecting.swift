import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

/// The device a tab shows, as persisted on the tab.
nonisolated enum DeviceTarget: Hashable, Sendable {
    case emulator(avdID: String)
    case physical(serial: String)

    /// Tabs from before physical devices carry an AVD id and may lack a platform.
    init?(platform: DevicePlatform?, identifier: String?) {
        guard let identifier, !identifier.isEmpty else { return nil }
        switch platform {
        case .androidPhysical: self = .physical(serial: identifier)
        case .androidEmulator, nil: self = .emulator(avdID: identifier)
        }
    }

    var platform: DevicePlatform {
        switch self {
        case .emulator: .androidEmulator
        case .physical: .androidPhysical
        }
    }

    var identifier: String {
        switch self {
        case .emulator(let avdID): avdID
        case .physical(let serial): serial
        }
    }

    var isPhysical: Bool { platform == .androidPhysical }
}

/// What a session connects to once its target has been found.
nonisolated enum ResolvedDevice: Sendable {
    case emulator(RunningEmulator)
    case physical(serial: String, adbURL: URL)
}

nonisolated struct DeviceFrame: @unchecked Sendable {
    enum Contents {
        case image(CGImage)
        /// The pixel buffer owns the surface and must outlive its use as layer contents.
        case surface(IOSurfaceRef, owner: CVPixelBuffer)
    }

    let contents: Contents
    let pixelSize: CGSize
    let rotation: DeviceRotation
    /// The natural-orientation size touches are sent in, when the frame defines it.
    let deviceSize: CGSize?

    var layerContents: Any {
        switch contents {
        case .image(let image): image
        case .surface(let surface, _): surface
        }
    }
}

nonisolated struct DeviceConnectionInfo: Sendable {
    /// Natural-orientation device pixels.
    var deviceSize: CGSize?
}

/// A point in device pixels, with the device size it was mapped against.
nonisolated struct DevicePoint: Sendable, Hashable {
    var point: CGPoint
    var deviceSize: CGSize
}

nonisolated enum DeviceTouchPhase: Sendable, Hashable {
    case down
    case move
    case up
}

nonisolated enum DeviceInput: Sendable, Hashable {
    case touch(DeviceTouchPhase, DevicePoint)
    /// Android wheel units, 120 per notch. `at` is where the pointer is, if it is over the screen.
    case scroll(at: DevicePoint?, dx: Int32, dy: Int32)
    case emulatorKey(DeviceKey)
    case androidKey(AndroidKeyInput)
}

nonisolated enum DeviceButton: Sendable, Hashable {
    case back
    case home
    case overview
    case power
    case volumeUp
    case volumeDown
}

nonisolated struct DeviceConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One live link to a device, emulator or physical, so the session and its tests never see a wire protocol.
nonisolated protocol DeviceConnecting: AnyObject, Sendable {
    func connect() async throws -> DeviceConnectionInfo
    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<DeviceFrame, Error>
    func send(_ input: DeviceInput)
    func press(_ button: DeviceButton, phase: DeviceKeyPhase)
    func rotate(to rotation: DeviceRotation) async throws
    func shutDown() async throws
    func close() async
    /// Starts releasing anything that would outlive the app, without waiting, so a quit right after
    /// can wait for it. `close()` still tears down the rest.
    func terminate()
}

extension AsyncThrowingStream where Failure == Error {
    /// Cancelling the result stops iterating `source`, so a consumer leaving releases the source too.
    nonisolated static func mapping<Source: Sendable>(
        _ source: AsyncThrowingStream<Source, Error>,
        mapError: @escaping @Sendable (Error) -> Error = { $0 },
        transform: @escaping @Sendable (Source) -> Element?
    ) -> AsyncThrowingStream<Element, Error> where Element: Sendable {
        let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached {
            do {
                for try await value in source {
                    if let mapped = transform(value) { continuation.yield(mapped) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: mapError(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
