import SwiftUI
import Testing

@testable import Plume

/// The sentence in the chat's empty state wraps through this layout, so what
/// matters is where it breaks lines and how tall the result is.
@MainActor
struct WrappingHStackTests {
    /// Six 40pt-wide boxes, which at 100pt of width fit two to a line.
    private func measure(width: CGFloat, boxes: Int = 6) -> CGSize {
        let layout = WrappingHStack(horizontalSpacing: 10, verticalSpacing: 4)
        let host = NSHostingView(rootView: AnyView(
            layout {
                ForEach(0..<boxes, id: \.self) { _ in
                    Color.clear.frame(width: 40, height: 20)
                }
            }
            .frame(width: width)
        ))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func aRowThatFitsStaysOnOneLine() {
        #expect(measure(width: 1000).height == 20)
    }

    @Test func aNarrowRowWrapsToSeveralLines() {
        // 40 + 10 + 40 = 90 fits in 100; a third box would need 140.
        let size = measure(width: 100)
        #expect(size.height == 20 * 3 + 4 * 2)
    }

    @Test func oneBoxPerLineWhenNothingElseFits() {
        let size = measure(width: 45, boxes: 3)
        #expect(size.height == 20 * 3 + 4 * 2)
    }

    @Test func aBoxWiderThanTheContainerStillGetsItsOwnLine() {
        let size = measure(width: 10, boxes: 2)
        #expect(size.height == 20 * 2 + 4)
    }
}
