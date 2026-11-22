import SwiftUI

/// Text that changes with one wipe from left to right: the new text shows
/// behind a trailing soft edge while the old text clears ahead of a leading
/// one, a fixed gap apart, so the two never overlap. With Reduce Motion on,
/// it crossfades instead. The first value shows without any animation, and
/// an idle text draws only `content`: no mask, no task, no geometry reader.
struct FadeWipeText<Content: View>: View {
    private let text: String
    /// What the text belongs to. A new key with the text means a different
    /// line took this one's place, so the text changes without a wipe.
    private let key: AnyHashable?
    private let content: (String) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: FadeWipeState
    /// Wipes run so far. It only ever grows, so no animation runs backward
    /// through a reset; a wipe's progress is its distance past `wipeStart`.
    @State private var sweeps: Double = 0
    @State private var wipeStart: Double = 0
    /// The wider of the two texts, which the wipe crosses.
    @State private var wipeWidth: CGFloat = 0

    static var wipe: Animation { .spring(duration: 0.45, bounce: 0) }
    /// Eases the frame to the new text's width, and so any icons after it,
    /// once the last wipe ends.
    static var settleWidth: Animation { .easeOut(duration: 0.2) }
    /// Far longer than a wipe, so it only fires when a completion was lost.
    static var watchdog: Duration { .seconds(1) }

    init(_ text: String, key: AnyHashable? = nil, @ViewBuilder content: @escaping (String) -> Content) {
        self.text = text
        self.key = key
        self.content = content
        _state = State(initialValue: FadeWipeState(text))
    }

    var body: some View {
        Group {
            if reduceMotion {
                content(text)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: text)
            } else if let outgoing = state.outgoing {
                FadeWipe(
                    sweeps: sweeps,
                    start: wipeStart,
                    width: wipeWidth,
                    outgoing: content(outgoing),
                    incoming: content(state.shown)
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wipeWidth = $0 }
                // A completion that never arrives would leave both texts drawn.
                .task(id: state.step) {
                    let step = state.step
                    try? await Task.sleep(for: Self.watchdog)
                    if state.step == step, state.phase != .idle { settle(on: state.target) }
                }
                .transition(.identity)
            } else {
                content(state.shown)
                    .transition(.identity)
            }
        }
        .onChange(of: Keyed(key: key, text: text)) { old, new in
            if reduceMotion || old.key != new.key {
                settle(on: new.text)
            } else {
                withAnimation(Self.wipe) { perform(state.retarget(new.text)) }
            }
        }
        // Unmounting mid-wipe drops its completion.
        .onAppear {
            if state.phase != .idle { settle(on: text) }
        }
    }

    private struct Keyed: Equatable {
        let key: AnyHashable?
        let text: String
    }

    private func settle(on text: String) {
        state.settle(on: text)
        sweeps = sweeps.rounded(.up)
    }

    /// Called inside an animation, so the frame changing width to fit both
    /// texts moves with it.
    private func perform(_ step: FadeWipeState.Step) {
        guard step == .wipe else { return }
        wipeStart = sweeps.rounded(.up)
        let token = state.step
        withAnimation(Self.wipe, completionCriteria: .logicallyComplete) {
            sweeps = wipeStart + 1
        } completion: {
            withAnimation(Self.settleWidth) { perform(state.stepFinished(token)) }
        }
    }
}

/// The text a wipe shows. A change mid-wipe only retargets it: the wipe in
/// flight finishes, then one more runs from what it showed to the latest text.
struct FadeWipeState: Equatable {
    enum Phase: Equatable {
        case idle, wiping
    }

    /// What the view starts next.
    enum Step: Equatable {
        case none, wipe
    }

    /// The text wiping in, or the only text while idle.
    private(set) var shown: String
    /// The text wiping out; nil while idle.
    private(set) var outgoing: String?
    private(set) var target: String
    private(set) var phase = Phase.idle
    /// Counts the wipes started and the settles, so a completion can say
    /// which wipe it finishes.
    private(set) var step = 0

    init(_ text: String) {
        shown = text
        target = text
    }

    mutating func retarget(_ text: String) -> Step {
        target = text
        guard phase == .idle, text != shown else { return .none }
        return startWipe()
    }

    /// Call when the wipe that `step` named has finished. A completion from
    /// any earlier wipe changes nothing.
    mutating func stepFinished(_ finished: Int) -> Step {
        guard finished == step, phase == .wiping else { return .none }
        outgoing = nil
        guard target != shown else {
            phase = .idle
            return .none
        }
        return startWipe()
    }

    /// Jumps straight to `text` and retires the wipe in flight, so its
    /// completion changes nothing.
    mutating func settle(on text: String) {
        shown = text
        outgoing = nil
        target = text
        phase = .idle
        step += 1
    }

    private mutating func startWipe() -> Step {
        outgoing = shown
        shown = target
        phase = .wiping
        step += 1
        return .wipe
    }
}

/// Both texts, leading-aligned, each masked by its own soft edge. One
/// progress value drives both edges, the old text's a fixed gap ahead of the
/// new text's, across the wider text plus both edges and the gap.
private struct FadeWipe<Content: View>: View, Animatable {
    var sweeps: Double
    let start: Double
    let width: CGFloat
    let outgoing: Content
    let incoming: Content

    var animatableData: Double {
        get { sweeps }
        set { sweeps = newValue }
    }

    /// Sized for the sidebar's title and caption lines: the gap reads as a
    /// clean break, and the edges stay soft without smearing a short word.
    static var softness: CGFloat { 14 }
    static var gap: CGFloat { 4 }

    var body: some View {
        let progress = CGFloat(min(max(sweeps - start, 0), 1))
        let travel = width + 2 * Self.softness + Self.gap
        // The old text shows right of `lead`, the new one left of `trail`.
        let lead = -Self.softness + progress * travel
        let trail = lead - Self.gap
        ZStack(alignment: .leading) {
            outgoing
                .accessibilityHidden(true)
                .mask { edge(from: lead, to: lead + Self.softness, colors: [.clear, .black]) }
            incoming.mask { edge(from: trail - Self.softness, to: trail, colors: [.black, .clear]) }
        }
        // Only `sweeps` animates. The next wipe swaps both texts and moves
        // both edges back to the start in an animated transaction, and
        // animating that would draw both texts over each other.
        .transaction { $0.animation = nil }
    }

    /// A gradient between two points measured from the leading edge.
    private func edge(from: CGFloat, to: CGFloat, colors: [Color]) -> some View {
        GeometryReader { proxy in
            let span = max(proxy.size.width, 1)
            LinearGradient(
                colors: colors,
                startPoint: UnitPoint(x: from / span, y: 0.5),
                endPoint: UnitPoint(x: to / span, y: 0.5)
            )
        }
    }
}
