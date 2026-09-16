import SwiftUI
import Testing

@testable import Plume

/// The sentence in the chat's empty state wraps through this layout, so what
/// matters is where it breaks lines and how tall the result is.
///
/// Every width is measured in one test. A hosting controller reports its
/// first `sizeThatFits` before the layout has settled, so a case measured
/// alone reads short; measuring the no-wrap width first settles it and the
/// rest are then honest.
@MainActor
struct WrappingHStackTests {
    /// `boxes` boxes of 40x20, spaced 10 apart horizontally and 4 vertically.
    private func height(width: CGFloat, boxes: Int = 6) -> CGFloat {
        let content = WrappingHStack(horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(0..<boxes, id: \.self) { _ in
                Color.clear.frame(width: 40, height: 20)
            }
        }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        _ = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    @Test func theSentenceBreaksWhereItRunsOutOfWidth() {
        let row: CGFloat = 20
        let gap: CGFloat = 4

        #expect(height(width: 1000) == row)
        // 40 + 10 + 40 = 90 fits in 100; a third box would need 140.
        #expect(height(width: 100) == row * 3 + gap * 2)
        #expect(height(width: 45, boxes: 3) == row * 3 + gap * 2)
        // Wider than the container still takes a line of its own rather than
        // leaving an empty one before it.
        #expect(height(width: 10, boxes: 2) == row * 2 + gap)
    }
}
