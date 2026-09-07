import SwiftUI

/// Reveals a growing string a character at a time.
///
/// `Text` content is not animatable, so the count is: SwiftUI interpolates
/// `animatableData` and rebuilds this body per frame, and the body takes that
/// many characters of the string. Nothing else in the chat animates a count,
/// so the type stays here rather than in a shared folder.
struct CharacterReveal<Content: View>: View, Animatable {
    var revealedCount: Double
    var text: String
    @ViewBuilder var content: (String) -> Content

    var animatableData: Double {
        get { revealedCount }
        set { revealedCount = newValue }
    }

    var body: some View {
        content(String(text.prefix(max(0, Int(revealedCount)))))
    }
}

/// How fast a character reveal runs.
///
/// The reveal is measured in characters, not frames or ticks, so the pacing is
/// a pure function of how much text is waiting and how many deltas have landed
/// while a reveal was already running. Each interruption shortens the reveal,
/// which is what keeps a fast stream from building a backlog the reader waits
/// out — and the uneven rhythm that produces is wanted.
enum RevealPacing {
    /// A comfortable rate for the first delta of a turn. Fast enough to feel
    /// like typing rather than a teleprompter.
    static let charactersPerSecond: Double = 220

    /// A whole paragraph landing at once still reveals in about a second.
    static let maxDuration: Double = 1.0

    /// The ceiling on how long text can sit between arriving and being fully
    /// on screen, waiting for the block above it included. Every reveal is
    /// retargeted at the whole text received so far, so this bounds the lag
    /// however fast the agent writes.
    static let maxLag: Double = maxDuration

    /// Below this a reveal reads as a jump, and the frames cost more than the
    /// effect is worth.
    static let minDuration: Double = 0.1

    /// What each delta arriving mid-reveal multiplies the duration by.
    static let speedupPerInterruption: Double = 0.7

    /// The floor on the compounded speed-up, so a long stream settles at a
    /// steady fast pace instead of converging on an instant paste.
    static let minSpeedup: Double = 0.25

    /// The multiplier for `interruptions` deltas landing while a reveal ran.
    static func speedup(interruptions: Int) -> Double {
        guard interruptions > 0 else { return 1 }
        return max(minSpeedup, pow(speedupPerInterruption, Double(interruptions)))
    }

    static func duration(pendingCharacters: Int, interruptions: Int) -> Double {
        guard pendingCharacters > 0 else { return 0 }
        let nominal = min(maxDuration, Double(pendingCharacters) / charactersPerSecond)
        return max(minDuration, nominal * speedup(interruptions: interruptions))
    }

    /// Eases out of a reveal that starts from rest, and runs the rest linearly
    /// — a curve retargeted mid-flight would otherwise change speed at every
    /// delta on top of the deliberate shortening.
    static func animation(pendingCharacters: Int, interruptions: Int) -> Animation {
        let duration = duration(pendingCharacters: pendingCharacters, interruptions: interruptions)
        return interruptions > 0 ? .linear(duration: duration) : .easeOut(duration: duration)
    }
}

/// The reveal's progress for one streaming overlay, advanced as text arrives.
///
/// A struct in `@State` rather than loose properties, so the bookkeeping that
/// decides an interruption stays next to the count it paces.
struct RevealProgress {
    /// Nil until the first text is seen. That first sight is assigned whole:
    /// a tab switched to mid-turn, or a row remounted, shows what has already
    /// arrived rather than replaying it.
    private(set) var revealedCount: Double?

    /// Starts this block from nothing, so a block the stream has just opened
    /// types rather than appearing whole.
    mutating func start() {
        revealedCount = 0
    }
    /// When the reveal in flight lands, for the block queued behind it.
    private(set) var deadline: Date = .distantPast
    private var interruptions = 0

    /// What the block owes once the stream stops writing it.
    ///
    /// Half the pace the same characters would have taken mid-stream: the
    /// block is finished, so the tail of it reads as catching up rather than
    /// as more typing, and the block starting below it gets its turn sooner.
    /// Nil when there is nothing left to reveal.
    mutating func finish(_ text: String, now: Date = .now) -> Animation? {
        let target = Double(text.count)
        guard let previous = revealedCount, target > previous else {
            revealedCount = target
            return nil
        }
        revealedCount = target
        interruptions = 0
        let duration = RevealPacing.duration(
            pendingCharacters: Int(target - previous),
            interruptions: 0
        ) / 2
        deadline = now.addingTimeInterval(duration)
        return .easeOut(duration: duration)
    }

    /// The pacing for the text now on hand, or nil when it should be shown
    /// without animating.
    mutating func advance(to text: String, now: Date = .now) -> Animation? {
        let target = Double(text.count)
        defer { revealedCount = target }

        guard let previous = revealedCount else { return nil }
        // A restart, or the transcript taking the overlay over: there is
        // nothing to reveal towards.
        guard target > previous else {
            interruptions = 0
            deadline = .distantPast
            return nil
        }

        interruptions = now < deadline ? interruptions + 1 : 0
        let pending = Int(target - previous)
        let animation = RevealPacing.animation(pendingCharacters: pending, interruptions: interruptions)
        deadline = now.addingTimeInterval(
            RevealPacing.duration(pendingCharacters: pending, interruptions: interruptions)
        )
        return animation
    }
}
