import SwiftUI

/// How a collapsible Home section opens and closes. Opening eases the
/// section's height open while each row waits for the height to reach it, then
/// fades and scales in; closing fades the rows out first, then eases the
/// height shut, so a row is never drawn over the content below it.
nonisolated enum HomeSectionReveal {
    static let heightDuration = 0.32
    static let rowFadeDuration = 0.22
    static let rowStartScale = 0.9
    static let collapseFadeDuration = 0.12
    static let collapseHeightDuration = 0.22

    /// `.easeOut`'s control points, spelled out so `rowDelay` can solve the
    /// same curve.
    private static let curveX = 0.58

    static var expandHeight: Animation {
        .timingCurve(0, 0, curveX, 1, duration: heightDuration)
    }

    static var collapseFade: Animation { .easeIn(duration: collapseFadeDuration) }
    static var collapseHeight: Animation { .easeInOut(duration: collapseHeightDuration) }

    /// When row `index` of `count` starts to fade in: once the height has
    /// opened halfway through that row's slot, taking rows as equal height.
    /// Rows run top down and overlap, and the last starts before the height
    /// settles however many there are.
    static func rowDelay(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let progress = min(max((Double(index) + 0.5) / Double(count), 0), 1)
        return heightDuration * timeFraction(atProgress: progress)
    }

    /// Inverts the ease-out curve: the fraction of its duration at which it
    /// has covered `progress` of the distance.
    static func timeFraction(atProgress progress: Double) -> Double {
        // With control points (0, 0) and (x, 1): y(s) = 3s² − 2s³, which is
        // monotonic on 0…1, so bisection finds s.
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let s = (low + high) / 2
            if 3 * s * s - 2 * s * s * s < progress { low = s } else { high = s }
        }
        let s = (low + high) / 2
        return 3 * (1 - s) * s * s * curveX + s * s * s
    }

    @MainActor
    static func rowTransition(index: Int, count: Int, reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity.animation(.easeOut(duration: 0.15))
            : .opacity.combined(with: .scale(scale: rowStartScale, anchor: .leading))
                .animation(.easeOut(duration: rowFadeDuration).delay(rowDelay(index: index, count: count)))
        return .asymmetric(insertion: insertion, removal: .opacity)
    }
}
