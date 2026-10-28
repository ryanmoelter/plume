import CoreGraphics
import EmulatorControl
import Foundation
import Testing

@testable import Plume

nonisolated final class FakeConnection: DeviceConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _frameRequests: [CGSize] = []
    private var _continuations: [AsyncThrowingStream<EmulatorFrame, Error>.Continuation] = []
    private var _inputs: [EmulatorInput] = []
    private var _presses: [(HardwareButton, KeyPhase)] = []
    private var _rotations: [EmulatorRotation] = []
    private var _shutDownCount = 0
    private var _closeCount = 0
    var statusResult: Result<EmulatorStatusSnapshot, Error> = .success(
        EmulatorStatusSnapshot(booted: true, version: "1", displaySize: CGSize(width: 1080, height: 2400))
    )

    var frameRequests: [CGSize] { lock.withLock { _frameRequests } }
    var inputs: [EmulatorInput] { lock.withLock { _inputs } }
    var presses: [(HardwareButton, KeyPhase)] { lock.withLock { _presses } }
    var rotations: [EmulatorRotation] { lock.withLock { _rotations } }
    var shutDownCount: Int { lock.withLock { _shutDownCount } }
    var closeCount: Int { lock.withLock { _closeCount } }

    func status() async throws -> EmulatorStatusSnapshot { try statusResult.get() }

    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<EmulatorFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<EmulatorFrame, Error>.makeStream()
        lock.withLock {
            _frameRequests.append(maxPixelSize)
            _continuations.append(continuation)
        }
        return stream
    }

    func send(_ input: EmulatorInput) { lock.withLock { _inputs.append(input) } }
    func press(_ button: HardwareButton, phase: KeyPhase) { lock.withLock { _presses.append((button, phase)) } }
    func rotate(to rotation: EmulatorRotation) async throws { lock.withLock { _rotations.append(rotation) } }
    func shutDown() async throws { lock.withLock { _shutDownCount += 1 } }
    func close() async { lock.withLock { _closeCount += 1 } }

    func push(_ frame: EmulatorFrame) {
        let continuation = lock.withLock { _continuations.last }
        continuation?.yield(frame)
    }

    func finishFrames() { lock.withLock { _continuations.last }?.finish() }

    func failFrames(_ error: Error) { lock.withLock { _continuations.last }?.finish(throwing: error) }
}

@MainActor
final class FakeSink: DeviceFrameSink {
    var requestedPixelSize: CGSize
    private(set) var presented: [EmulatorFrame] = []
    init(size: CGSize) { requestedPixelSize = size }
    func present(_ frame: EmulatorFrame) { presented.append(frame) }
}

private struct StreamError: LocalizedError {
    var errorDescription: String? { "stream broke" }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}

private func makeImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

private func makeFrame(rotation: EmulatorRotation = .portrait, seq: UInt32 = 0) -> EmulatorFrame {
    EmulatorFrame(image: makeImage(), pixelSize: CGSize(width: 1, height: 1), rotation: rotation, seq: seq)
}

private func makeRunning(avdID: String = "Pixel_8", name: String = "Pixel 8") -> RunningEmulator {
    RunningEmulator(
        pid: 1, avdID: avdID, avdName: name, avdDirectory: nil, grpcPort: 8554, grpcToken: "t",
        adbPort: nil, serialPort: nil, version: nil, fileURL: URL(fileURLWithPath: "pid_1.ini")
    )
}

@MainActor
private struct Harness {
    let session: DeviceSession
    let fake: FakeConnection

    init(avdID: String? = "Pixel_8", fake: FakeConnection = FakeConnection()) {
        self.fake = fake
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emulator-session-\(UUID().uuidString)", isDirectory: true)
        session = DeviceSession(
            tabID: UUID(), avdID: avdID, displayName: avdID,
            discovery: EmulatorDiscovery(directories: [directory]),
            makeConnection: { _ in fake }
        )
    }

    func connected() async {
        session.attach(makeRunning())
        await waitUntil { session.state == .connected }
    }
}

/// Covers the session's state machine, sink-driven streaming, input gating and teardown against a fake connection.
@MainActor
struct DeviceSessionTests {
    @Test func newSessionWithoutAvdNeedsDevice() {
        #expect(Harness(avdID: nil).session.state == .needsDevice)
    }

    @Test func startWithUnrunningAvdEndsNotRunning() async {
        let h = Harness()
        #expect(h.session.state == .locating)
        h.session.start()
        await waitUntil { h.session.state == .notRunning }
        #expect(h.session.state == .notRunning)
    }

    @Test func attachConnectsAndReportsDevice() async {
        let h = Harness(avdID: nil)
        var reported: [(String?, String?)] = []
        h.session.onDeviceChange = { reported.append(($0, $1)) }
        h.session.attach(makeRunning())
        #expect(h.session.state == .connecting)
        await waitUntil { h.session.state == .connected }
        #expect(h.session.state == .connected)
        #expect(h.session.deviceSize == CGSize(width: 1080, height: 2400))
        #expect(reported.count == 1)
        #expect(reported.first?.0 == "Pixel_8")
        #expect(reported.first?.1 == "Pixel 8")
    }

    @Test func streamFollowsSinkLifecycle() async {
        let h = Harness()
        await h.connected()
        #expect(h.fake.frameRequests.isEmpty)
        #expect(!h.session.isStreaming)

        let empty = FakeSink(size: .zero)
        h.session.addSink(empty)
        #expect(h.fake.frameRequests.isEmpty)
        #expect(!h.session.isStreaming)
        h.session.removeSink(empty)

        let sink = FakeSink(size: CGSize(width: 400, height: 800))
        h.session.addSink(sink)
        #expect(h.fake.frameRequests == [CGSize(width: 400, height: 800)])
        #expect(h.session.isStreaming)

        h.session.removeSink(sink)
        #expect(!h.session.isStreaming)
    }

    @Test func framesReachEverySinkAndUpdateRotation() async {
        let h = Harness()
        await h.connected()
        let a = FakeSink(size: CGSize(width: 100, height: 200))
        let b = FakeSink(size: CGSize(width: 50, height: 100))
        h.session.addSink(a)
        h.session.addSink(b)
        #expect(h.session.rotation == .portrait)

        h.fake.push(makeFrame(rotation: .landscape, seq: 1))
        await waitUntil { a.presented.count == 1 && b.presented.count == 1 }
        #expect(a.presented.count == 1)
        #expect(b.presented.count == 1)
        #expect(h.session.rotation == .landscape)
    }

    @Test func sinkSizeChangeRestartsOnlyWhenLargestRequestMoves() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        #expect(h.fake.frameRequests.count == 1)

        h.session.sinkSizeChanged()
        #expect(h.fake.frameRequests.count == 1)

        sink.requestedPixelSize = CGSize(width: 300, height: 600)
        h.session.sinkSizeChanged()
        #expect(h.fake.frameRequests == [CGSize(width: 100, height: 200), CGSize(width: 300, height: 600)])
    }

    @Test func failingStreamDisconnects() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.fake.failFrames(StreamError())
        await waitUntil { h.session.state != .connected }
        #expect(h.session.state == .disconnected("stream broke"))
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
        #expect(!h.session.isStreaming)
    }

    @Test func finishingStreamDisconnects() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.fake.finishFrames()
        await waitUntil { h.session.state != .connected }
        guard case .disconnected = h.session.state else {
            Issue.record("expected .disconnected, got \(h.session.state)")
            return
        }
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
    }

    @Test func closeClosesConnectionWithoutShuttingDown() async {
        let h = Harness()
        await h.connected()
        h.session.close()
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
        #expect(h.fake.shutDownCount == 0)
    }

    @Test func shutDownEmulatorShutsDownAndLeavesNotRunning() async {
        let h = Harness()
        await h.connected()
        h.session.shutDownEmulator()
        #expect(h.session.state == .notRunning)
        await waitUntil { h.fake.shutDownCount == 1 && h.fake.closeCount == 1 }
        #expect(h.fake.shutDownCount == 1)
        #expect(h.fake.closeCount == 1)
        #expect(h.session.state == .notRunning)
    }

    @Test func inputIsDroppedUnlessConnected() async {
        let h = Harness()
        let wheel = EmulatorInput.wheel(dx: 0, dy: 1)
        h.session.send(wheel)
        h.session.press(.home)
        #expect(h.fake.inputs.isEmpty)
        #expect(h.fake.presses.isEmpty)

        h.session.attach(makeRunning())
        h.session.send(wheel)
        #expect(h.fake.inputs.isEmpty)

        await waitUntil { h.session.state == .connected }
        h.session.send(wheel)
        #expect(h.fake.inputs == [wheel])
    }

    @Test func pressSendsDownThenUp() async {
        let h = Harness()
        await h.connected()
        h.session.press(.home)
        #expect(h.fake.presses.map(\.0) == [.home, .home])
        #expect(h.fake.presses.map(\.1) == [.down, .up])
    }

    @Test func changeDeviceReturnsToPicker() async {
        let h = Harness()
        await h.connected()
        var reported: [(String?, String?)] = []
        h.session.onDeviceChange = { reported.append(($0, $1)) }
        h.session.changeDevice()
        #expect(h.session.state == .needsDevice)
        #expect(h.session.avdID == nil)
        #expect(reported.count == 1)
        #expect(reported.first?.0 == nil)
        #expect(reported.first?.1 == nil)
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
    }

    @Test func rotateAsksForAdjacentOrientation() async {
        let h = Harness()
        await h.connected()
        h.session.rotate(clockwise: true)
        await waitUntil { h.fake.rotations.count == 1 }
        #expect(h.fake.rotations == [.reverseLandscape])

        h.session.rotate(clockwise: false)
        await waitUntil { h.fake.rotations.count == 2 }
        #expect(h.fake.rotations.last == .landscape)
    }
}
