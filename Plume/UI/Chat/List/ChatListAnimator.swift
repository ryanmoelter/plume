import AppKit
import QuartzCore

/// The one clock behind every motion in the custom chat list: height eases,
/// the arrival of a new piece, the composer's room, and a programmatic scroll.
///
/// A single display link rather than one animation per row, so the
/// controller applies every in-flight value in one layout pass per frame. A
/// scroll target is re-resolved on every tick, which is what lets a jump aim
/// at an item whose offset is still moving as its neighbours measure.
@MainActor
final class ChatListAnimator: NSObject {
    nonisolated struct Ease {
        var from: CGFloat
        var to: CGFloat
        var start: TimeInterval
        var duration: TimeInterval

        func value(at now: TimeInterval) -> CGFloat {
            from + (to - from) * progress(at: now)
        }

        func progress(at now: TimeInterval) -> CGFloat {
            guard duration > 0 else { return 1 }
            let t = min(max((now - start) / duration, 0), 1)
            return ChatListAnimator.easeOut(CGFloat(t))
        }

        func isFinished(at now: TimeInterval) -> Bool {
            now - start >= duration
        }
    }

    /// A scroll whose destination is a rule, not a number.
    nonisolated struct Scroll {
        var from: CGFloat
        var start: TimeInterval
        var duration: TimeInterval
        var target: ChatListScrollTarget

        func progress(at now: TimeInterval) -> CGFloat {
            guard duration > 0 else { return 1 }
            let t = min(max((now - start) / duration, 0), 1)
            return ChatListAnimator.easeInOut(CGFloat(t))
        }

        func isFinished(at now: TimeInterval) -> Bool {
            now - start >= duration
        }
    }

    private(set) var eases: [String: Ease] = [:]
    private(set) var scroll: Scroll?
    private var displayLink: CADisplayLink?
    private weak var view: NSView?

    /// Runs once per frame while anything is animating, after the animator
    /// has advanced. The controller reads `eases` and `scroll` from it.
    var onTick: ((TimeInterval) -> Void)?

    init(view: NSView) {
        self.view = view
        super.init()
    }

    deinit {
        displayLink?.invalidate()
    }

    var isAnimating: Bool { !eases.isEmpty || scroll != nil }

    func ease(_ key: String, from: CGFloat, to: CGFloat, duration: TimeInterval) {
        eases[key] = Ease(from: from, to: to, start: CACurrentMediaTime(), duration: duration)
        resume()
    }

    func cancelEase(_ key: String) {
        eases[key] = nil
    }

    func value(of key: String, at now: TimeInterval) -> CGFloat? {
        eases[key]?.value(at: now)
    }

    func beginScroll(from: CGFloat, to target: ChatListScrollTarget, duration: TimeInterval) {
        scroll = Scroll(from: from, start: CACurrentMediaTime(), duration: duration, target: target)
        resume()
    }

    func cancelScroll() {
        scroll = nil
    }

    /// Drops what has finished, after the controller has applied its final
    /// value, and stops the clock once nothing is left.
    func prune(at now: TimeInterval) {
        eases = eases.filter { !$0.value.isFinished(at: now) }
        if let scroll, scroll.isFinished(at: now) { self.scroll = nil }
        if !isAnimating { displayLink?.isPaused = true }
    }

    private func resume() {
        if displayLink == nil, let view {
            let link = view.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        onTick?(CACurrentMediaTime())
    }

    nonisolated static func easeOut(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 3)
    }

    nonisolated static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// Where a programmatic scroll is heading.
nonisolated enum ChatListScrollTarget: Equatable {
    case bottom
    /// The item's slot at the top of the viewport.
    case item(String)
}
