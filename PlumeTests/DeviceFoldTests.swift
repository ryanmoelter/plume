import CoreGraphics
import EmulatorControl
import Foundation
import Testing

@testable import Plume

private nonisolated final class FoldableConnection: DeviceConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let postures: [DevicePosture]
    private var _posture: DevicePosture?
    private var _setPostures: [DevicePosture] = []
    private var _postureReads = 0
    var failsToSetPosture = false

    init(postures: [DevicePosture], posture: DevicePosture?) {
        self.postures = postures
        _posture = posture
    }

    var setPostures: [DevicePosture] { lock.withLock { _setPostures } }
    var postureReads: Int { lock.withLock { _postureReads } }

    func connect() async throws -> DeviceConnectionInfo {
        DeviceConnectionInfo(deviceSize: CGSize(width: 2076, height: 2152), postures: postures)
    }

    func posture() async -> DevicePosture? {
        lock.withLock {
            _postureReads += 1
            return _posture
        }
    }

    func setPosture(_ posture: DevicePosture) async throws {
        let fails = lock.withLock {
            _setPostures.append(posture)
            return failsToSetPosture
        }
        if fails { throw DeviceConnectionError(message: "refused") }
        lock.withLock { _posture = posture }
    }

    func frames(maxPixelSize: CGSize) -> AsyncThrowingStream<DeviceFrame, Error> { AsyncThrowingStream { _ in } }
    func send(_ input: DeviceInput) {}
    func press(_ button: DeviceButton, phase: DeviceKeyPhase) {}
    func paste(text: String) {}
    func rotate(to rotation: DeviceRotation) async throws {}
    func autoRotate() async -> Bool? { nil }
    func setAutoRotate(_ enabled: Bool) async -> Bool { false }
    func shutDown() async throws {}
    func close() async {}
    func terminate() {}
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
private func connectedSession(to connection: FoldableConnection) async -> DeviceSession {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("fold-session-\(UUID().uuidString)", isDirectory: true)
    let session = DeviceSession(
        tabID: UUID(), target: nil, displayName: nil,
        discovery: EmulatorDiscovery(directories: [directory]),
        physicalDiscovery: PhysicalDeviceDiscovery { ADBListing(adbURL: nil, devices: []) },
        makeConnection: { _ in connection },
        idleSleep: { _ in }
    )
    session.attach(RunningEmulator(
        pid: 1, avdID: "Pixel_9_Pro_Fold", avdName: "Pixel 9 Pro Fold", avdDirectory: nil, grpcPort: 8554, grpcToken: "t",
        adbPort: nil, serialPort: nil, version: nil, fileURL: URL(fileURLWithPath: "pid_1.ini")
    ))
    await waitUntil { session.state == .connected }
    return session
}

/// Covers reading an AVD's hinge from its config and the session's fold posture controls.
@MainActor
struct DeviceFoldTests {
    @Test func aHingeOffersItsListedPostures() {
        let config = ["hw.sensor.hinge": "yes", "hw.sensor.posture_list": "1, 2, 3"]
        #expect(EmulatorConnection.postures(fromConfig: config) == [.closed, .halfOpen, .open])
    }

    @Test func aHingeWithoutAPostureListOffersTheCommonThree() {
        #expect(EmulatorConnection.postures(fromConfig: ["hw.sensor.hinge": "true"]) == [.closed, .halfOpen, .open])
    }

    @Test func noHingeOffersNoPostures() {
        #expect(EmulatorConnection.postures(fromConfig: [:]).isEmpty)
        #expect(EmulatorConnection.postures(fromConfig: ["hw.sensor.hinge": "no", "hw.sensor.posture_list": "1, 2, 3"]).isEmpty)
    }

    @Test func posturesWithoutAControlAreDropped() {
        let postures = EmulatorConnection.postures(fromConfig: ["hw.sensor.hinge": "yes", "hw.sensor.posture_list": "1, 3, 5, 9"])
        #expect(postures == [.closed, .open, .tent])
        #expect(postures.compactMap(DevicePosture.init) == [.closed, .open])
    }

    @Test func connectingReadsTheCurrentPosture() async {
        let connection = FoldableConnection(postures: [.closed, .halfOpen, .open], posture: .halfOpen)
        let session = await connectedSession(to: connection)
        await waitUntil { session.posture != nil }
        #expect(session.postures == [.closed, .halfOpen, .open])
        #expect(session.posture == .halfOpen)
    }

    @Test func aDeviceWithoutAHingeNeverReadsAPosture() async {
        let connection = FoldableConnection(postures: [], posture: .open)
        let session = await connectedSession(to: connection)
        #expect(session.postures.isEmpty)
        #expect(session.posture == nil)
        #expect(connection.postureReads == 0)
    }

    @Test func settingAPostureShowsItAtOnce() async {
        let connection = FoldableConnection(postures: [.closed, .halfOpen, .open], posture: .open)
        let session = await connectedSession(to: connection)
        await waitUntil { session.posture == .open }

        session.setPosture(.closed)
        #expect(session.posture == .closed)
        await waitUntil { connection.setPostures == [.closed] }
        #expect(connection.setPostures == [.closed])
    }

    @Test func aRefusedPostureFallsBackToTheDevicesOwn() async {
        let connection = FoldableConnection(postures: [.closed, .halfOpen, .open], posture: .open)
        connection.failsToSetPosture = true
        let session = await connectedSession(to: connection)
        await waitUntil { session.posture == .open }

        session.setPosture(.closed)
        await waitUntil { connection.postureReads == 2 && session.posture == .open }
        #expect(session.posture == .open)
    }

    @Test func anUnofferedPostureIsIgnored() async {
        let connection = FoldableConnection(postures: [.closed, .open], posture: .open)
        let session = await connectedSession(to: connection)
        session.setPosture(.halfOpen)
        #expect(connection.setPostures.isEmpty)
    }

    @Test func changingDeviceForgetsTheHinge() async {
        let connection = FoldableConnection(postures: [.closed, .halfOpen, .open], posture: .open)
        let session = await connectedSession(to: connection)
        await waitUntil { session.posture == .open }

        session.changeDevice()
        #expect(session.postures.isEmpty)
        #expect(session.posture == nil)
    }
}
