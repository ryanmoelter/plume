import Foundation
import ScrcpyControl

/// When a streamed frame was shown on the device and when it reached the Mac.
nonisolated struct DeviceFrameTiming: Sendable, Equatable {
    /// On the device's clock, whose origin means nothing on the Mac.
    var presentation: Duration
    var arrival: ContinuousClock.Instant
}

/// How far a stream has fallen behind: how much later than its fastest recent frame a frame
/// arrives, relative to its presentation time. A constant network delay reads as no lag.
nonisolated struct StreamLagMeter {
    /// The fastest frame is forgotten after this, so slow drift between the two clocks never
    /// accumulates into lag.
    static let baselineWindow: Duration = .seconds(60)

    private var origin: ContinuousClock.Instant?
    private var lastPresentation: Duration?
    /// Candidates for the fastest transit in the window, oldest first, with rising transit.
    private var fastest: [(arrival: ContinuousClock.Instant, transit: Duration)] = []

    mutating func record(_ timing: DeviceFrameTiming) -> Duration {
        // An encoder restart, on a rotation say, can start its clock again.
        if let lastPresentation, timing.presentation < lastPresentation { reset() }
        lastPresentation = timing.presentation
        let origin = origin ?? timing.arrival
        self.origin = origin
        let transit = (timing.arrival - origin) - timing.presentation
        while let last = fastest.last, last.transit >= transit { fastest.removeLast() }
        fastest.append((timing.arrival, transit))
        while let first = fastest.first, timing.arrival - first.arrival > Self.baselineWindow { fastest.removeFirst() }
        return transit - fastest[0].transit
    }

    mutating func reset() {
        origin = nil
        lastPresentation = nil
        fastest = []
    }
}

/// The video limits a device steps through, best first. The first is the ceiling the device
/// would stream at anyway.
nonisolated struct VideoQualityLadder: Equatable {
    static let rungs: [ScrcpyVideoLimits] = [
        ScrcpyVideoLimits(maxSize: 1280, videoBitRate: 4_000_000, maxFps: 30),
        ScrcpyVideoLimits(maxSize: 1024, videoBitRate: 2_000_000, maxFps: 30),
        ScrcpyVideoLimits(maxSize: 800, videoBitRate: 1_000_000, maxFps: 30),
    ]

    let levels: [ScrcpyVideoLimits]

    init(ceiling: ScrcpyVideoLimits) {
        levels = [ceiling] + Self.rungs.filter { rung in
            rung.maxSize! < (ceiling.maxSize ?? .max) && rung.videoBitRate! < (ceiling.videoBitRate ?? .max)
        }
    }

    var ceiling: ScrcpyVideoLimits { levels[0] }

    func name(of level: Int) -> String {
        let limits = levels[level]
        guard let maxSize = limits.maxSize, let bitRate = limits.videoBitRate else { return "Native" }
        return "\(maxSize) px, \(bitRate / 1_000_000) Mbit/s"
    }
}

nonisolated enum VideoQualityChoice: Hashable, Sendable {
    case automatic
    /// An index into the ladder's levels.
    case fixed(Int)
}

/// Steps a stream down its ladder while it falls behind, and back up once it keeps up.
/// Each step means a reconnect, since scrcpy-server takes its limits only at launch.
nonisolated struct VideoQualityGovernor {
    static let laggingThreshold: Duration = .milliseconds(500)
    /// How long frames must keep arriving late before a step down.
    static let laggingHold: Duration = .seconds(2)
    static let healthyThreshold: Duration = .milliseconds(150)
    static let initialHealthyHold: Duration = .seconds(30)
    static let maximumHealthyHold: Duration = .seconds(480)
    /// A step down this soon after a step up means the higher level can't be sustained, so the
    /// next attempt waits twice as long.
    static let bounceWindow: Duration = .seconds(60)

    private(set) var ladder: VideoQualityLadder
    private(set) var level = 0
    private(set) var choice: VideoQualityChoice = .automatic
    private(set) var healthyHold = Self.initialHealthyHold
    private var meter = StreamLagMeter()
    private var laggingSince: ContinuousClock.Instant?
    private var healthySince: ContinuousClock.Instant?
    private var lastStepUp: ContinuousClock.Instant?

    init(ceiling: ScrcpyVideoLimits) {
        ladder = VideoQualityLadder(ceiling: ceiling)
    }

    var limits: ScrcpyVideoLimits { ladder.levels[level] }

    /// A new connection's frames share no clock origin with the last one's.
    mutating func connectionStarted() {
        meter.reset()
        laggingSince = nil
        healthySince = nil
    }

    /// Returns whether the level changed.
    mutating func choose(_ choice: VideoQualityChoice) -> Bool {
        self.choice = choice
        guard case .fixed(let fixed) = choice else { return false }
        let target = min(max(fixed, 0), ladder.levels.count - 1)
        guard target != level else { return false }
        level = target
        return true
    }

    /// Returns the new level when the stream should reconnect at it.
    mutating func record(_ timing: DeviceFrameTiming) -> Int? {
        guard choice == .automatic else { return nil }
        let lag = meter.record(timing)
        let now = timing.arrival
        if lag > Self.laggingThreshold {
            healthySince = nil
            let since = laggingSince ?? now
            laggingSince = since
            guard now - since >= Self.laggingHold, level < ladder.levels.count - 1 else { return nil }
            if let lastStepUp, now - lastStepUp < Self.bounceWindow {
                healthyHold = min(healthyHold * 2, Self.maximumHealthyHold)
            }
            lastStepUp = nil
            return step(to: level + 1)
        }
        laggingSince = nil
        guard lag < Self.healthyThreshold else {
            healthySince = nil
            return nil
        }
        let since = healthySince ?? now
        healthySince = since
        guard now - since >= healthyHold, level > 0 else { return nil }
        lastStepUp = now
        return step(to: level - 1)
    }

    private mutating func step(to newLevel: Int) -> Int {
        level = newLevel
        connectionStarted()
        return newLevel
    }
}
