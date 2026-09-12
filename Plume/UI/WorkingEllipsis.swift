import SwiftUI

/// An ellipsis whose dots light one after another, the way a chat app shows
/// someone typing. Shared by the sidebar badge and the chat caption so the two
/// stay in step.
///
/// Two details are load-bearing:
///
/// `.symbolRenderingMode(.hierarchical)` is what makes the three dots
/// addressable as separate layers. Monochrome — the default — gives
/// `.variableColor` nothing to walk, so it cycles the whole symbol's opacity
/// instead and the dots light and dim in unison.
///
/// `.variableColor` animates in the render server rather than through the view
/// graph, so unlike a `repeatForever` opacity animation it costs no per-frame
/// SwiftUI update. That matters most in the chat, where this sits in the same
/// stack as the message list.
struct WorkingEllipsis: View {
    var color: Color

    var body: some View {
        Image(systemName: "ellipsis")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .symbolEffect(
                .variableColor.iterative.dimInactiveLayers.nonReversing,
                options: .repeat(.continuous)
            )
    }
}

#Preview {
    WorkingEllipsis(color: .accentColor)
        .padding()
}
