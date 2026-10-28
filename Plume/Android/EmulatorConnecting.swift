import CoreGraphics
import EmulatorControl

/// The slice of `EmulatorConnection` a session uses, so tests can stand in a fake.
nonisolated protocol EmulatorConnecting: AnyObject, Sendable {
    func status() async throws -> EmulatorStatusSnapshot
    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<EmulatorFrame, Error>
    func send(_ input: EmulatorInput)
    func press(_ button: HardwareButton, phase: KeyPhase)
    func rotate(to rotation: EmulatorRotation) async throws
    func shutDown() async throws
    func close() async
}

extension EmulatorConnection: EmulatorConnecting {
    nonisolated func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<EmulatorFrame, Error> {
        frames(maxPixelSize: maxPixelSize, useSharedMemory: true)
    }
}
