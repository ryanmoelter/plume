import SwiftUI

/// Text that changes with a fade swipe: a soft edge sweeps the old text out
/// from left to right, and after a short pause sweeps the new text in the
/// same way. With Reduce Motion on, it crossfades instead. The first value
/// shows without any animation.
struct FadeSwipeText<Content: View>: View {
    private let text: String
    private let content: (String) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipe: FadeSwipe
    /// Sweeps run so far. It only ever grows, so no animation runs backward
    /// through a reset: an even value shows the text, an odd one hides it.
    @State private var sweeps: Double = 0

    static var fadeOut: Animation { .easeInOut(duration: 0.2) }
    static var pause: TimeInterval { 0.06 }
    static var fadeIn: Animation { .easeOut(duration: 0.25) }

    init(_ text: String, @ViewBuilder content: @escaping (String) -> Content) {
        self.text = text
        self.content = content
        _swipe = State(initialValue: FadeSwipe(text))
    }

    var body: some View {
        Group {
            if reduceMotion {
                content(text)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: text)
            } else {
                content(swipe.shown)
                    .modifier(FadeSwipeMask(sweeps: sweeps))
            }
        }
        .onChange(of: text) { _, new in
            if reduceMotion {
                swipe.settle(on: new)
                sweeps = (sweeps / 2).rounded(.up) * 2
            } else {
                perform(swipe.retarget(new))
            }
        }
    }

    private func perform(_ step: FadeSwipe.Step) {
        switch step {
        case .none:
            break
        case .fadeOut:
            sweep(Self.fadeOut)
        case .pause:
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause) {
                perform(swipe.stepFinished())
            }
        case .fadeIn:
            sweep(Self.fadeIn)
        }
    }

    private func sweep(_ animation: Animation) {
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            sweeps += 1
        } completion: {
            perform(swipe.stepFinished())
        }
    }
}

/// The phases of a fade swipe. A change that lands mid-swipe only retargets
/// it: the text that shows next is whatever is latest when the old text has
/// gone, and a change during the fade-in runs another swipe once it ends.
struct FadeSwipe: Equatable {
    enum Phase: Equatable {
        case idle, fadingOut, pausing, fadingIn
    }

    /// What the view starts next.
    enum Step: Equatable {
        case none, fadeOut, pause, fadeIn
    }

    private(set) var shown: String
    private(set) var target: String
    private(set) var phase = Phase.idle

    init(_ text: String) {
        shown = text
        target = text
    }

    mutating func retarget(_ text: String) -> Step {
        target = text
        guard phase == .idle, text != shown else { return .none }
        phase = .fadingOut
        return .fadeOut
    }

    /// Call when the step last returned has finished.
    mutating func stepFinished() -> Step {
        switch phase {
        case .idle:
            return .none
        case .fadingOut:
            phase = .pausing
            return .pause
        case .pausing:
            shown = target
            phase = .fadingIn
            return .fadeIn
        case .fadingIn:
            guard target != shown else {
                phase = .idle
                return .none
            }
            phase = .fadingOut
            return .fadeOut
        }
    }

    /// Jumps straight to `text`. A step still in flight then finishes as a no-op.
    mutating func settle(on text: String) {
        shown = text
        target = text
        phase = .idle
    }
}

/// Masks its content with a soft edge at `sweeps`' fractional part across the
/// width: a sweep from an even value hides what is left of the edge, and one
/// from an odd value shows it.
private struct FadeSwipeMask: ViewModifier, Animatable {
    var sweeps: Double

    var animatableData: Double {
        get { sweeps }
        set { sweeps = newValue }
    }

    /// The soft edge's width, as a fraction of the content's.
    private static let softness = 0.4

    func body(content: Content) -> some View {
        let whole = sweeps.rounded(.down)
        let progress = sweeps - whole
        let hides = Int(whole).isMultiple(of: 2)
        let start = -Self.softness + progress * (1 + Self.softness)
        content.mask {
            LinearGradient(
                colors: hides ? [.clear, .black] : [.black, .clear],
                startPoint: UnitPoint(x: start, y: 0.5),
                endPoint: UnitPoint(x: start + Self.softness, y: 0.5)
            )
        }
    }
}
