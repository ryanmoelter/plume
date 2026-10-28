import CoreGraphics
import Foundation
import Testing

@testable import Plume

nonisolated final class FakeConnection: DeviceConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _frameRequests: [CGSize] = []
    private var _continuations: [AsyncThrowingStream<DeviceFrame, Error>.Continuation] = []
    private var _inputs: [DeviceInput] = []
    private var _presses: [(DeviceButton, DeviceKeyPhase)] = []
    private var _rotations: [DeviceRotation] = []
    private var _shutDownCount = 0
    private var _closeCount = 0
    private var _connectCount = 0
    private var _terminateCount = 0
    private var _cancelledStreams = 0
    var connectResult: Result<DeviceConnectionInfo, Error> = .success(
        DeviceConnectionInfo(deviceSize: CGSize(width: 1080, height: 2400))
    )

    var frameRequests: [CGSize] { lock.withLock { _frameRequests } }
    var inputs: [DeviceInput] { lock.withLock { _inputs } }
    var presses: [(DeviceButton, DeviceKeyPhase)] { lock.withLock { _presses } }
    var rotations: [DeviceRotation] { lock.withLock { _rotations } }
    var shutDownCount: Int { lock.withLock { _shutDownCount } }
    var closeCount: Int { lock.withLock { _closeCount } }
    var connectCount: Int { lock.withLock { _connectCount } }
    var terminateCount: Int { lock.withLock { _terminateCount } }
    var cancelledStreams: Int { lock.withLock { _cancelledStreams } }

    func connect() async throws -> DeviceConnectionInfo {
        lock.withLock { _connectCount += 1 }
        return try connectResult.get()
    }

    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<DeviceFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<DeviceFrame, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            self.lock.withLock { self._cancelledStreams += 1 }
        }
        lock.withLock {
            _frameRequests.append(maxPixelSize)
            _continuations.append(continuation)
        }
        return stream
    }

    func send(_ input: DeviceInput) { lock.withLock { _inputs.append(input) } }
    func press(_ button: DeviceButton, phase: DeviceKeyPhase) { lock.withLock { _presses.append((button, phase)) } }
    func rotate(to rotation: DeviceRotation) async throws { lock.withLock { _rotations.append(rotation) } }
    func shutDown() async throws { lock.withLock { _shutDownCount += 1 } }
    func close() async { lock.withLock { _closeCount += 1 } }
    func terminate() { lock.withLock { _terminateCount += 1 } }

    func push(_ frame: DeviceFrame) {
        let continuation = lock.withLock { _continuations.last }
        continuation?.yield(frame)
    }

    func finishFrames() { lock.withLock { _continuations.last }?.finish() }

    func failFrames(_ error: Error) { lock.withLock { _continuations.last }?.finish(throwing: error) }
}

@MainActor
final class FakeSink: DeviceFrameSink {
    var requestedPixelSize: CGSize
    private(set) var presented: [DeviceFrame] = []
    init(size: CGSize) { requestedPixelSize = size }
    func present(_ frame: DeviceFrame) { presented.append(frame) }
}

/// Stands in for the idle-stop clock: every sleep waits until the test fires it. A cancelled sleep
/// leaves `pending` at once, so a test waiting for the next sleep never counts a stale one.
@MainActor
final class ManualSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var pending: Int { waiters.count }

    func sleep(_ duration: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            // The session cancels its idle stop from the main actor.
            MainActor.assumeIsolated { self.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    func fire() {
        let waiters = waiters
        self.waiters = [:]
        waiters.values.forEach { $0.resume() }
    }
}

nonisolated final class ListingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _listing: ADBListing
    private var _listCount = 0
    init(_ listing: ADBListing) { _listing = listing }
    var listCount: Int { lock.withLock { _listCount } }
    func list() -> ADBListing {
        lock.withLock {
            _listCount += 1
            return _listing
        }
    }
    var listing: ADBListing {
        get { lock.withLock { _listing } }
        set { lock.withLock { _listing = newValue } }
    }
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

private func makeFrame(rotation: DeviceRotation = .portrait, deviceSize: CGSize? = nil) -> DeviceFrame {
    DeviceFrame(contents: .image(makeImage()), pixelSize: CGSize(width: 1, height: 1), rotation: rotation, deviceSize: deviceSize)
}

private func makeRunning(avdID: String = "Pixel_8", name: String = "Pixel 8") -> RunningEmulator {
    RunningEmulator(
        pid: 1, avdID: avdID, avdName: name, avdDirectory: nil, grpcPort: 8554, grpcToken: "t",
        adbPort: nil, serialPort: nil, version: nil, fileURL: URL(fileURLWithPath: "pid_1.ini")
    )
}

private let adbURL = URL(fileURLWithPath: "/sdk/platform-tools/adb")
private let pixel = PhysicalDevice(serial: "S1", state: .ready, model: "Pixel_9")

@MainActor
private struct Harness {
    let session: DeviceSession
    let fake: FakeConnection
    let adb: ListingBox
    let physicalDiscovery: PhysicalDeviceDiscovery
    let sleeper = ManualSleeper()

    init(
        target: DeviceTarget? = .emulator(avdID: "Pixel_8"),
        devices: [PhysicalDevice] = [],
        fake: FakeConnection = FakeConnection()
    ) {
        self.fake = fake
        let adb = ListingBox(ADBListing(adbURL: adbURL, devices: devices))
        self.adb = adb
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("emulator-session-\(UUID().uuidString)", isDirectory: true)
        let sleeper = sleeper
        let physicalDiscovery = PhysicalDeviceDiscovery { adb.list() }
        self.physicalDiscovery = physicalDiscovery
        session = DeviceSession(
            tabID: UUID(), target: target, displayName: target?.identifier,
            discovery: EmulatorDiscovery(directories: [directory]),
            physicalDiscovery: physicalDiscovery,
            makeConnection: { _ in fake },
            idleSleep: { await sleeper.sleep($0) }
        )
    }

    func connected() async {
        session.attach(makeRunning())
        await waitUntil { session.state == .connected }
    }

    /// Lists adb first, as the picker does before offering the device.
    func connectedPhysically() async {
        adb.listing.devices = [pixel]
        await physicalDiscovery.refresh()
        session.attach(pixel)
        await waitUntil { session.state == .connected }
    }
}

/// Covers the session's state machine, sink-driven streaming, input gating and teardown against a fake connection.
@MainActor
struct DeviceSessionTests {
    @Test func newSessionWithoutAvdNeedsDevice() {
        #expect(Harness(target: nil).session.state == .needsDevice)
    }

    @Test func startWithUnrunningAvdEndsNotRunning() async {
        let h = Harness()
        #expect(h.session.state == .locating)
        h.session.start()
        await waitUntil { h.session.state == .notRunning }
        #expect(h.session.state == .notRunning)
    }

    @Test func attachConnectsAndReportsDevice() async {
        let h = Harness(target: nil)
        var reported: [(DeviceTarget?, String?)] = []
        h.session.onDeviceChange = { reported.append(($0, $1)) }
        h.session.attach(makeRunning())
        #expect(h.session.state == .connecting)
        await waitUntil { h.session.state == .connected }
        #expect(h.session.state == .connected)
        #expect(h.session.deviceSize == CGSize(width: 1080, height: 2400))
        #expect(reported.count == 1)
        #expect(reported.first?.0 == .emulator(avdID: "Pixel_8"))
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

        h.fake.push(makeFrame(rotation: .landscape))
        await waitUntil { a.presented.count == 1 && b.presented.count == 1 }
        #expect(a.presented.count == 1)
        #expect(b.presented.count == 1)
        #expect(h.session.rotation == .landscape)
    }

    @Test func reconnectingKeepsAnEmulatorsRotation() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.fake.push(makeFrame(rotation: .landscape))
        await waitUntil { h.session.rotation == .landscape }

        h.session.attach(makeRunning())
        await waitUntil { h.fake.connectCount == 2 && h.session.state == .connected }
        #expect(h.fake.connectCount == 2)
        #expect(h.session.rotation == .landscape)
    }

    @Test func connectingAPhysicalDeviceResetsRotation() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.fake.push(makeFrame(rotation: .landscape))
        await waitUntil { h.session.rotation == .landscape }

        await h.connectedPhysically()
        await waitUntil { h.fake.connectCount == 2 && h.session.state == .connected }
        #expect(h.fake.connectCount == 2)
        #expect(h.session.rotation == .portrait)
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

    @Test func closeStartsReleasingTheConnectionBeforeReturning() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        h.session.close()
        #expect(h.fake.terminateCount == 1)
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
        let wheel = DeviceInput.scroll(at: nil, dx: 0, dy: 1)
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
        var reported: [(DeviceTarget?, String?)] = []
        h.session.onDeviceChange = { reported.append(($0, $1)) }
        h.session.changeDevice()
        #expect(h.session.state == .needsDevice)
        #expect(h.session.target == nil)
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

    // MARK: Physical devices

    @Test func physicalTargetThatAdbDoesNotListIsNotRunning() async {
        let h = Harness(target: .physical(serial: "S1"))
        h.session.start()
        await waitUntil { h.session.state == .notRunning }
        #expect(h.session.state == .notRunning)
        #expect(h.fake.frameRequests.isEmpty)
    }

    @Test func unauthorizedPhysicalDeviceIsNotRunning() async {
        let h = Harness(target: .physical(serial: "S1"), devices: [PhysicalDevice(serial: "S1", state: .unauthorized, model: nil)])
        h.session.start()
        await waitUntil { h.session.state == .notRunning }
        #expect(h.session.state == .notRunning)
    }

    @Test func retryConnectsOnceTheDeviceAppears() async {
        let h = Harness(target: .physical(serial: "S1"))
        h.session.start()
        await waitUntil { h.session.state == .notRunning }
        h.adb.listing.devices = [pixel]
        h.session.locate()
        await waitUntil { h.session.state == .connected }
        #expect(h.session.state == .connected)
    }

    @Test func attachingAPhysicalDeviceReportsItsTarget() async {
        let h = Harness(target: nil)
        var reported: [(DeviceTarget?, String?)] = []
        h.session.onDeviceChange = { reported.append(($0, $1)) }
        await h.connectedPhysically()
        #expect(h.session.state == .connected)
        #expect(h.session.isPhysical)
        #expect(reported.first?.0 == .physical(serial: "S1"))
        #expect(reported.first?.1 == "Pixel 9")
    }

    @Test func attachingAPhysicalDeviceConnectsWithoutListingAdbAgain() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        #expect(h.adb.listCount == 1)
        #expect(h.fake.connectCount == 1)
    }

    @Test func attachingBeforeAdbWasListedLooksItUp() async {
        let h = Harness(target: nil, devices: [pixel])
        h.session.attach(pixel)
        await waitUntil { h.session.state == .connected }
        #expect(h.session.state == .connected)
        #expect(h.adb.listCount == 1)
    }

    @Test func physicalStreamIgnoresResizes() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        sink.requestedPixelSize = CGSize(width: 300, height: 600)
        h.session.sinkSizeChanged()
        #expect(h.fake.frameRequests.count == 1)
    }

    @Test func graceExpiryClosesThePhysicalConnection() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.session.removeSink(sink)
        #expect(h.session.isStreaming)
        await waitUntil { h.sleeper.pending == 1 }
        #expect(h.fake.closeCount == 0)

        h.sleeper.fire()
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
        #expect(h.fake.terminateCount == 1)
        #expect(h.session.state == .suspended)
        #expect(!h.session.isStreaming)
    }

    @Test func aHiddenPhysicalConnectionClosesAfterTheGraceEvenUnwatched() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        await waitUntil { h.sleeper.pending == 1 }
        h.sleeper.fire()
        await waitUntil { h.session.state == .suspended }
        #expect(h.session.state == .suspended)
        #expect(h.fake.frameRequests.isEmpty)
    }

    @Test func sinkReturningAfterTheGraceReconnects() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.session.removeSink(sink)
        await waitUntil { h.sleeper.pending == 1 }
        h.sleeper.fire()
        await waitUntil { h.session.state == .suspended }
        #expect(h.fake.connectCount == 1)

        h.session.addSink(sink)
        #expect(h.session.state == .connecting)
        await waitUntil { h.session.isStreaming }
        #expect(h.session.state == .connected)
        #expect(h.fake.connectCount == 2)
        #expect(h.fake.frameRequests.count == 2)
    }

    @Test func sinkReturningWithinTheGraceKeepsTheConnection() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.fake.push(makeFrame())
        await waitUntil { sink.presented.count == 1 }
        h.session.removeSink(sink)
        await waitUntil { h.sleeper.pending == 1 }

        let returning = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(returning)
        #expect(returning.presented.count == 1)
        h.sleeper.fire()
        for _ in 0..<100 { await Task.yield() }
        #expect(h.session.isStreaming)
        #expect(h.session.state == .connected)
        #expect(h.fake.connectCount == 1)
        #expect(h.fake.closeCount == 0)
        #expect(h.fake.frameRequests.count == 1)
        #expect(h.fake.cancelledStreams == 0)
    }

    @Test func terminateReleasesTheConnectionWithoutWaiting() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        h.session.terminate()
        #expect(h.fake.terminateCount == 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(h.fake.closeCount == 0)
    }

    @Test func emulatorStreamStopsAtOnceWhenItsLastSinkLeaves() async {
        let h = Harness()
        await h.connected()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)
        h.session.removeSink(sink)
        #expect(!h.session.isStreaming)
        #expect(h.sleeper.pending == 0)
    }

    @Test func deviceSizeFollowsTheVideoSize() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        #expect(h.session.deviceSize == CGSize(width: 1080, height: 2400))
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        h.session.addSink(sink)

        h.fake.push(makeFrame(deviceSize: CGSize(width: 2400, height: 1080)))
        await waitUntil { sink.presented.count == 1 }
        #expect(h.session.deviceSize == CGSize(width: 2400, height: 1080))
        #expect(h.session.rotation == .portrait)
    }

    @Test func closingAPhysicalSessionNeverShutsTheDeviceDown() async {
        let h = Harness(target: nil)
        await h.connectedPhysically()
        h.session.shutDownEmulator()
        #expect(h.session.state == .connected)
        #expect(!h.session.canShutDownEmulator)

        h.session.close()
        await waitUntil { h.fake.closeCount == 1 }
        #expect(h.fake.closeCount == 1)
        #expect(h.fake.shutDownCount == 0)
    }
}
