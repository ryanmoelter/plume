import CoreGraphics
import Foundation

/// Where each pane sits across the detail width, and where the divider
/// between two panes sits. Panes are numbered from the left, as
/// `WorkTask.panes` numbers them.
struct SplitLayout: Equatable {
    struct Pane: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    static let dividerWidth: CGFloat = 1

    let panes: [Pane]
    let width: CGFloat
    let minimumPaneWidth: CGFloat

    init(paneCount: Int, fraction: Double, width: CGFloat, minimumPaneWidth: CGFloat) {
        self.width = width
        self.minimumPaneWidth = minimumPaneWidth
        guard paneCount == 2 else {
            panes = [Pane(x: 0, width: width)]
            return
        }
        let leading = Self.leadingWidth(
            fraction: fraction, width: width, minimumPaneWidth: minimumPaneWidth
        )
        let trailingX = leading + Self.dividerWidth
        panes = [
            Pane(x: 0, width: leading),
            Pane(x: trailingX, width: max(0, width - trailingX)),
        ]
    }

    var isSplit: Bool { panes.count > 1 }

    var dividerX: CGFloat? {
        isSplit ? panes[0].width : nil
    }

    func pane(_ index: Int) -> Pane? {
        panes.indices.contains(index) ? panes[index] : nil
    }

    /// The fraction that puts the divider at `x`, held to each pane's floor.
    func fraction(forDividerAt x: CGFloat) -> Double {
        let available = width - Self.dividerWidth
        guard available > 0 else { return 0.5 }
        let leading = Self.clampedLeadingWidth(x, available: available, minimumPaneWidth: minimumPaneWidth)
        return Double(leading / available)
    }

    /// The side a drop at `x` lands on: the pane under it while split,
    /// otherwise the half, where a new pane would open.
    func side(forX x: CGFloat) -> TaskStore.SplitSide {
        x < (dividerX ?? width / 2) ? .left : .right
    }

    private static func leadingWidth(fraction: Double, width: CGFloat, minimumPaneWidth: CGFloat) -> CGFloat {
        let available = max(0, width - dividerWidth)
        return clampedLeadingWidth(
            (available * CGFloat(fraction)).rounded(), available: available, minimumPaneWidth: minimumPaneWidth
        )
    }

    /// Too narrow for both floors means an even split rather than one pane
    /// squeezed to nothing.
    private static func clampedLeadingWidth(_ leading: CGFloat, available: CGFloat, minimumPaneWidth: CGFloat) -> CGFloat {
        guard available >= minimumPaneWidth * 2 else { return (available / 2).rounded() }
        return min(max(leading, minimumPaneWidth), available - minimumPaneWidth)
    }
}
