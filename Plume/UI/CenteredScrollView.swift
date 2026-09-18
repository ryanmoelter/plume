import SwiftUI

/// A scroll view whose content sits centred while it fits, and scrolls once it
/// does not.
///
/// The measurement has to happen outside the `ScrollView`: a scroll view
/// proposes its content an unbounded height, so a `GeometryReader` within one
/// reports that rather than the viewport and the minimum comes out near zero.
struct CenteredScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                content
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
            }
        }
    }
}
