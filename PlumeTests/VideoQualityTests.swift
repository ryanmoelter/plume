import CoreGraphics
import Foundation
import ScrcpyControl
import Synchronization
import Testing
@testable import Plume

private let origin = ContinuousClock.now

/// A frame shown on the device at `seconds` that took `delay` longer than the fastest one to arrive.
private func timing(_ seconds: Double, delay: Double = 0) -> DeviceFrameTiming {
    DeviceFrameTiming(presentation: .milliseconds(milliseconds(seconds)), arrival: origin + .milliseconds(milliseconds(seconds + delay)))
}

private func milliseconds(_ seconds: Double) -> Int {
    Int((seconds * 1000).rounded())
}

/// Feeds a frame every 100 ms from `start` up to but not including `end`, and returns each level change.
private func feed(
    _ governor: inout VideoQualityGovernor, from start: Double, to end: Double, delay: Double
) -> [(at: Double, level: Int)] {
    var changes: [(Double, Int)] = []
    for step in 0..<Int(((end - start) * 10).rounded(.up)) {
        let time = start + Double(step) / 10
        if let level = governor.record(timing(time, delay: delay)) { changes.append((time, level)) }
    }
    return changes
}

/// The lag meter reads how much later than the fastest recent frame each frame arrives, so a
/// steady network delay is no lag, and it forgets the fastest frame after its window.
struct StreamLagMeterTests {
    @Test func aConstantDelayIsNoLag() {
        var meter = StreamLagMeter()
        let lags = (0..<20).map { meter.record(DeviceFrameTiming(presentation: .milliseconds(100 * $0), arrival: origin + .milliseconds(100 * $0 + 300))) }
        #expect(lags.allSatisfy { $0 == .zero })
    }

    @Test func aGrowingDelayIsLag() {
        var meter = StreamLagMeter()
        _ = meter.record(timing(0))
        _ = meter.record(timing(1, delay: 0.25))
        #expect(meter.record(timing(2, delay: 0.7)) == .milliseconds(700))
    }

    @Test func aPresentationClockThatRestartsStartsAFreshBaseline() {
        var meter = StreamLagMeter()
        _ = meter.record(timing(10))
        // Arrives a second later but presents at 0: a restarted encoder, not 11 seconds of lag.
        #expect(meter.record(DeviceFrameTiming(presentation: .zero, arrival: origin + .seconds(11))) == .zero)
    }

    @Test func theFastestFrameIsForgottenAfterTheWindow() {
        var meter = StreamLagMeter()
        _ = meter.record(timing(0))
        #expect(meter.record(timing(59, delay: 0.2)) == .milliseconds(200))
        #expect(meter.record(timing(62, delay: 0.2)) == .zero)
    }
}

/// The ladder starts at the device's own limits and adds only the rungs below them.
struct VideoQualityLadderTests {
    @Test func aUSBDeviceStepsFromNativeThroughEveryRung() {
        let ladder = VideoQualityLadder(ceiling: .none)
        #expect(ladder.levels == [.none] + VideoQualityLadder.rungs)
        #expect(ladder.name(of: 0) == "Native")
        #expect(ladder.name(of: 3) == "800 px, 1 Mbit/s")
    }

    @Test func aRemoteDeviceStepsFromItsOwnLimits() {
        let ladder = VideoQualityLadder(ceiling: .remoteDevice)
        #expect(ladder.levels.map(\.maxSize) == [1280, 1024, 800])
        #expect(ladder.levels.map(\.videoBitRate) == [4_000_000, 2_000_000, 1_000_000])
    }
}

/// The governor steps down once frames keep arriving late for `laggingHold`, steps up after
/// `healthyHold` of frames on time, and doubles that hold when a step up falls straight back.
struct VideoQualityGovernorTests {
    @Test func aBriefStallStaysPut() {
        var governor = VideoQualityGovernor(ceiling: .none)
        #expect(feed(&governor, from: 0, to: 1, delay: 0).isEmpty)
        #expect(feed(&governor, from: 1, to: 2.5, delay: 0.8).isEmpty)
        #expect(feed(&governor, from: 2.5, to: 4, delay: 0).isEmpty)
        #expect(governor.level == 0)
    }

    @Test func sustainedLagStepsDownOneLevel() {
        var governor = VideoQualityGovernor(ceiling: .none)
        _ = feed(&governor, from: 0, to: 1, delay: 0)
        let changes = feed(&governor, from: 1, to: 4, delay: 0.8)
        #expect(changes.map(\.level) == [1])
        // The first late frame is at 1 s, so the hold runs out at 3 s.
        #expect(abs((changes.first?.at ?? 0) - 3) < 0.05)
        #expect(governor.limits == VideoQualityLadder.rungs[0])
    }

    @Test func theLowestLevelStaysPutWhileLagging() {
        var governor = VideoQualityGovernor(ceiling: .remoteDevice)
        let changed = governor.choose(.fixed(2))
        #expect(changed)
        _ = governor.choose(.automatic)
        _ = feed(&governor, from: 0, to: 1, delay: 0)
        #expect(feed(&governor, from: 1, to: 10, delay: 0.8).isEmpty)
        #expect(governor.level == 2)
    }

    @Test func aHealthyStreamStepsBackUpAfterTheHold() {
        var governor = VideoQualityGovernor(ceiling: .none)
        _ = feed(&governor, from: 0, to: 1, delay: 0)
        _ = feed(&governor, from: 1, to: 3.05, delay: 0.8)
        #expect(governor.level == 1)
        governor.connectionStarted()
        let changes = feed(&governor, from: 10, to: 41, delay: 0)
        #expect(changes.map(\.level) == [0])
        #expect(abs((changes.first?.at ?? 0) - 40) < 0.05)
    }

    @Test func aStepUpThatFallsBackDoublesTheHold() {
        var governor = VideoQualityGovernor(ceiling: .none)
        _ = feed(&governor, from: 0, to: 1, delay: 0)
        _ = feed(&governor, from: 1, to: 3.05, delay: 0.8)
        _ = feed(&governor, from: 10, to: 40.05, delay: 0)
        #expect(governor.level == 0)
        // Lags again 20 s after stepping up, inside the bounce window.
        _ = feed(&governor, from: 60, to: 61, delay: 0)
        _ = feed(&governor, from: 61, to: 63.05, delay: 0.8)
        #expect(governor.level == 1)
        #expect(governor.healthyHold == .seconds(60))
        #expect(feed(&governor, from: 70, to: 100, delay: 0).isEmpty)
        #expect(feed(&governor, from: 100, to: 130.05, delay: 0).map(\.level) == [0])
    }

    @Test func aFixedChoiceStopsAdapting() {
        var governor = VideoQualityGovernor(ceiling: .none)
        let first = governor.choose(.fixed(1))
        let again = governor.choose(.fixed(1))
        #expect(first)
        #expect(!again)
        _ = feed(&governor, from: 0, to: 1, delay: 0)
        #expect(feed(&governor, from: 1, to: 10, delay: 0.8).isEmpty)
        #expect(feed(&governor, from: 10, to: 100, delay: 0).isEmpty)
        #expect(governor.level == 1)
    }
}

/// A session reconnects its scrcpy stream one level lower when frames fall behind, and a manual
/// choice reconnects at the level picked.
@MainActor
struct DeviceSessionVideoQualityTests {
    private let fake = FakeConnection()
    private let limits = LimitsRecorder()
    private let pixel = PhysicalDevice(serial: "S1", state: .ready, model: "Pixel_9")

    private func connectedSession() async -> DeviceSession {
        let adb = ListingBox(ADBListing(adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb"), devices: [pixel]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-quality-\(UUID().uuidString)")
        let physicalDiscovery = PhysicalDeviceDiscovery { adb.list() }
        let (fake, limits) = (fake, limits)
        let session = DeviceSession(
            tabID: UUID(), target: nil,
            discovery: EmulatorDiscovery(directories: [directory]),
            physicalDiscovery: physicalDiscovery,
            makeConnection: { device in
                if case .physical(_, _, let deviceLimits) = device { limits.withLock { $0.append(deviceLimits) } }
                return fake
            },
            idleSleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        await physicalDiscovery.refresh()
        session.attach(pixel)
        await waitUntil { session.state == .connected }
        return session
    }

    private func frame(_ timing: DeviceFrameTiming) -> DeviceFrame {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return DeviceFrame(
            contents: .image(context.makeImage()!), pixelSize: CGSize(width: 1, height: 1), rotation: .portrait,
            deviceSize: CGSize(width: 1080, height: 2400), timing: timing
        )
    }

    @Test func framesFallingBehindReconnectOneLevelLower() async {
        let session = await connectedSession()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        #expect(session.videoQualityLevels == ["Native", "1280 px, 4 Mbit/s", "1024 px, 2 Mbit/s", "800 px, 1 Mbit/s"])

        for step in 0..<40 {
            let seconds = Double(step) / 10
            fake.push(frame(timing(seconds, delay: seconds < 1 ? 0 : 0.8)))
        }
        await waitUntil { limits.withLock { $0.count } == 2 }
        await waitUntil { session.state == .connected }

        #expect(limits.withLock { $0 } == [.none, VideoQualityLadder.rungs[0]])
        #expect(session.videoQualityLevel == 1)
        #expect(session.state == .connected)
    }

    @Test func choosingALevelReconnectsAtIt() async {
        let session = await connectedSession()
        session.setVideoQuality(.fixed(3))
        await waitUntil { limits.withLock { $0.count } == 2 }

        #expect(limits.withLock { $0.last } == VideoQualityLadder.rungs[2])
        #expect(session.videoQualityChoice == .fixed(3))
    }

    @Test func changingDeviceForgetsTheChoice() async {
        let session = await connectedSession()
        session.setVideoQuality(.fixed(2))
        session.changeDevice()

        #expect(session.videoQualityLevels.isEmpty)
        #expect(session.videoQualityChoice == .automatic)
        #expect(session.videoQualityLevel == 0)
    }
}

private nonisolated final class LimitsRecorder: Sendable {
    private let recorded = Mutex<[ScrcpyVideoLimits]>([])
    func withLock<T>(_ body: (inout [ScrcpyVideoLimits]) -> T) -> T { recorded.withLock { body(&$0) } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}
