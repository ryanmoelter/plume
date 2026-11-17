#if DEBUG
import AppKit
import OSLog
import QuartzCore

extension InProcessControlBackend {
    func scrollChat(_ params: ScrollChatParams) async throws -> ScrollHitchReport {
        let destination = try params.destination()
        _ = try params.clockChoice()
        let controller = try chatListController()
        guard controller.scrollView.window != nil else { throw ControlError.notFound("chat list") }
        guard ScrollHitchProbe.active == nil else { throw ControlError.badParams("a scrollChat is already running") }

        let activity = ControlActivity.begin(reason: "Measuring a chat scroll")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let report = await withCheckedContinuation { continuation in
            let driver = ScrollChatDriver(controller: controller, destination: destination, params: params) {
                continuation.resume(returning: $0)
            }
            driver.start()
        }
        Log.app.info("scroll-hitch \(report.logLine, privacy: .public)")
        return report
    }
}

/// Where `SwitchLatencyProbe.time` and `note` also report while a `scrollChat`
/// runs.
@MainActor
enum ScrollHitchProbe {
    fileprivate(set) static var active: ScrollChatDriver?

    static var isActive: Bool { active != nil }

    static func record(_ name: String, ms: Double?) {
        active?.record(name, ms: ms)
    }
}

/// Moves the chat list's clip view on every frame the way a wheel does, and
/// records one `ScrollFrameSample` per tick.
@MainActor
final class ScrollChatDriver: NSObject {
    private enum Clock { case displayLink, timer }

    private static let timerPeriod = 1.0 / 120
    /// How long the display link may stay silent before the timer takes
    /// over: before its first tick, and after one.
    private static let firstTickLimit = 0.1
    private static let silenceLimit = 1.0
    /// A watchdog this late was held off by a busy main thread, which holds
    /// off a display-link callback just as long, so the link gets this much
    /// longer to show it is still running.
    private static let lateFireSlack = 0.05
    private static let graceAfterStall = 0.1

    private let controller: ChatListController
    private let destination: ScrollChatParams.Destination
    private let params: ScrollChatParams
    private let completion: (ScrollHitchReport) -> Void

    private var link: CADisplayLink?
    private var timer: Timer?
    private var watchdog: Timer?
    private var watchdogDue: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var clock = Clock.displayLink
    private let forcesTimer: Bool
    private var linkTicks = 0
    private var timerTicks = 0

    private var startedAt: CFTimeInterval = 0
    private var startOffset: CGFloat = 0
    private var byTarget: CGFloat = 0
    private var lastTick: CFTimeInterval?
    private var arrivedAt: CFTimeInterval?
    private var awaitingTurnEnd = false
    private var turnWorkMs: Double?
    private var realizationsAtLastTick = 0
    private var intervalSpans: [String: SwitchLatencySpan] = [:]
    private var samples: [ScrollFrameSample] = []

    init(
        controller: ChatListController, destination: ScrollChatParams.Destination,
        params: ScrollChatParams, completion: @escaping (ScrollHitchReport) -> Void
    ) {
        self.controller = controller
        self.destination = destination
        self.params = params
        forcesTimer = (try? params.clockChoice()) == .timer
        if forcesTimer { clock = .timer }
        self.completion = completion
    }

    func start() {
        ScrollHitchProbe.active = self
        startedAt = CACurrentMediaTime()
        startOffset = controller.scrollView.contentView.bounds.origin.y
        if case let .by(points) = destination { byTarget = startOffset + CGFloat(points) }
        realizationsAtLastTick = controller.realizations

        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { ScrollHitchProbe.active?.turnEnded() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        if forcesTimer {
            startTimer()
        } else {
            let link = controller.scrollView.displayLink(target: self, selector: #selector(linkFired(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            // An occluded window or a sleeping display stops vsync, and the
            // display link with it.
            armWatchdog(after: Self.firstTickLimit, now: startedAt)
        }
    }

    fileprivate func record(_ name: String, ms: Double?) {
        if let ms {
            intervalSpans[name, default: SwitchLatencySpan(name: name)].add(ms: ms)
        } else {
            intervalSpans[name, default: SwitchLatencySpan(name: name)].count += 1
        }
    }

    @objc private func linkFired(_ link: CADisplayLink) {
        guard clock == .displayLink else { return }
        let now = CACurrentMediaTime()
        linkTicks += 1
        armWatchdog(after: Self.silenceLimit, now: now)
        tick(at: now, period: link.duration > 0 ? link.duration : Self.timerPeriod)
    }

    /// Moves the one watchdog's fire date rather than scheduling a timer per
    /// tick.
    private func armWatchdog(after delay: CFTimeInterval, now: CFTimeInterval) {
        watchdogDue = now + delay
        let fireDate = Date(timeIntervalSinceNow: watchdogDue - CACurrentMediaTime())
        if let watchdog {
            watchdog.fireDate = fireDate
            return
        }
        let watchdog = Timer(fire: fireDate, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { ScrollHitchProbe.active?.watchdogFired() }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    fileprivate func watchdogFired() {
        watchdog = nil
        guard clock == .displayLink else { return }
        let now = CACurrentMediaTime()
        if now - watchdogDue > Self.lateFireSlack {
            armWatchdog(after: Self.graceAfterStall, now: now)
            return
        }
        clock = .timer
        link?.invalidate()
        link = nil
        startTimer()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: Self.timerPeriod, repeats: true) { _ in
            MainActor.assumeIsolated { ScrollHitchProbe.active?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    fileprivate func timerFired() {
        timerTicks += 1
        tick(at: CACurrentMediaTime(), period: Self.timerPeriod)
    }

    fileprivate func turnEnded() {
        guard awaitingTurnEnd, let lastTick else { return }
        awaitingTurnEnd = false
        turnWorkMs = (CACurrentMediaTime() - lastTick) * 1000
    }

    private func tick(at now: CFTimeInterval, period: CFTimeInterval) {
        let realizationDelta = controller.realizations - realizationsAtLastTick
        let spans = intervalSpans.values.sorted { $0.ms != $1.ms ? $0.ms > $1.ms : $0.name < $1.name }
        let intervalMs = lastTick.map { (now - $0) * 1000 }
        let workMs = awaitingTurnEnd ? nil : turnWorkMs
        let dt = min(now - (lastTick ?? now), 0.1)
        intervalSpans.removeAll()
        realizationsAtLastTick = controller.realizations
        lastTick = now
        awaitingTurnEnd = true
        turnWorkMs = nil

        let offset = advance(by: CGFloat(params.speed * dt), at: now)
        samples.append(ScrollFrameSample(
            index: samples.count, offset: Double(offset), intervalMs: intervalMs, periodMs: period * 1000,
            workMs: workMs, realizations: realizationDelta, spans: spans
        ))

        if let arrivedAt, now - arrivedAt >= params.settle {
            finish(timedOut: false)
        } else if now - startedAt >= params.maxSeconds {
            finish(timedOut: true)
        }
    }

    /// Steps the clip toward the destination, re-read every tick because the
    /// document grows and shrinks as rows measure. Returns the offset left.
    private func advance(by step: CGFloat, at now: CFTimeInterval) -> CGFloat {
        let scrollView = controller.scrollView
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        let goal: CGFloat = switch destination {
        case .top: 0
        case .bottom: maxY
        case .by: min(max(byTarget, 0), maxY)
        }
        var origin = clip.bounds.origin
        let remaining = goal - origin.y
        if abs(remaining) > 0.5 {
            origin.y = abs(remaining) <= step ? goal : origin.y + (remaining > 0 ? step : -step)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
        let offset = clip.bounds.origin.y
        if abs(goal - offset) <= 0.5 {
            if arrivedAt == nil { arrivedAt = now }
        } else {
            arrivedAt = nil
        }
        return offset
    }

    private func finish(timedOut: Bool) {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        watchdog?.invalidate()
        watchdog = nil
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        ScrollHitchProbe.active = nil

        let clockName = switch (linkTicks > 0, timerTicks > 0) {
        case (true, true): "mixed"
        case (false, true): "timer"
        default: "displayLink"
        }
        let report = ScrollHitchReport(
            clock: clockName,
            startOffset: Double(startOffset),
            endOffset: Double(controller.scrollView.contentView.bounds.origin.y),
            timedOut: timedOut,
            samples: samples,
            worst: params.worst
        )
        completion(report)
    }
}
#endif
