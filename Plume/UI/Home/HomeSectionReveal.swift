import CoreGraphics
import SwiftUI

/// How a collapsible Home section opens and closes. Opening springs the
/// section's height open while each row waits for the height to reach it,
/// then fades in. Closing fades the rows out first, then springs the height
/// shut, so a row is never drawn over the content below it. Every spring is
/// critically damped, like the chat's word reveal, and the height takes longer
/// the more rows it moves, up to a cap.
nonisolated enum HomeSectionReveal {
    static let expandBaseDuration = 0.3
    static let expandDurationPerRow = 0.03
    static let expandMaxDuration = 0.5
    static let collapseBaseDuration = 0.2
    static let collapseDurationPerRow = 0.02
    static let collapseMaxDuration = 0.32
    /// The chat reveal's word fade duration.
    static let rowFadeDuration = 0.3
    static let collapseFadeDuration = 0.12

    static func expandDuration(count: Int) -> Double {
        min(expandBaseDuration + expandDurationPerRow * Double(max(count, 0)), expandMaxDuration)
    }

    static func collapseDuration(count: Int) -> Double {
        min(collapseBaseDuration + collapseDurationPerRow * Double(max(count, 0)), collapseMaxDuration)
    }

    static func expandHeight(count: Int) -> Animation {
        .spring(duration: expandDuration(count: count), bounce: 0)
    }

    static func collapseHeight(count: Int) -> Animation {
        .spring(duration: collapseDuration(count: count), bounce: 0)
    }

    static var rowEntrance: Animation { .spring(duration: rowFadeDuration, bounce: 0) }
    static var collapseFade: Animation { .easeIn(duration: collapseFadeDuration) }
    static var chevron: Animation { .spring(duration: 0.25, bounce: 0) }

    /// When row `index` of `count` starts to fade in: once the height has
    /// opened halfway through that row's slot, taking rows as equal height.
    /// Rows run top down and overlap, and the last starts before the height
    /// settles however many there are.
    static func rowDelay(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let progress = min(max((Double(index) + 0.5) / Double(count), 0), 1)
        return time(reaching: progress, duration: expandDuration(count: count))
    }

    /// When the opening spring has covered `progress` of the distance.
    static func time(reaching progress: Double, duration: Double) -> Double {
        let spring = Spring(duration: duration, bounce: 0)
        var low = 0.0, high = duration
        guard spring.value(target: 1.0, time: high) > progress else { return duration }
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if spring.value(target: 1.0, time: mid) < progress { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// How far to scroll down so an opened section's rows show, given the
    /// section's edges measured from the top of the visible area. Nothing when
    /// the section already fits; otherwise just enough to bring its bottom
    /// into view, but never so far that the header passes the top.
    static func scrollDelta(headerTop: CGFloat, sectionBottom: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        guard sectionBottom > visibleHeight else { return 0 }
        return max(0, min(sectionBottom - visibleHeight, headerTop))
    }

    @MainActor
    static func rowTransition(index: Int, count: Int, reduceMotion: Bool) -> AnyTransition {
        let insertion: AnyTransition
        if reduceMotion {
            insertion = .opacity.animation(.easeOut(duration: 0.15))
        } else {
            insertion = AnyTransition.opacity.animation(rowEntrance.delay(rowDelay(index: index, count: count)))
        }
        return .asymmetric(insertion: insertion, removal: .opacity)
    }
}
