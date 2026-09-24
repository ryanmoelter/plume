import SwiftUI

/// What the custom chat list tells one hosted item, mutated from outside the
/// SwiftUI root so a height ease never replaces the root view.
@MainActor
@Observable
final class ChatListItemState {
    /// The height the container is drawing this item at. Nil draws the
    /// natural height, which is what the list uses with motion turned off.
    var containerHeight: CGFloat?
    /// Off for a piece the stream is writing, so a new line draws whole below
    /// the eased frame instead of being cut off while its space opens.
    var clipsContent = true

    init(containerHeight: CGFloat? = nil) {
        self.containerHeight = containerHeight
    }
}

extension View {
    /// Draws this view at the height the container chose, reporting its
    /// natural height so the container can choose again.
    ///
    /// The measurement is taken inside `fixedSize`, so it is the ideal height
    /// and never the frame this modifier applies — the container's choice
    /// cannot feed back into its own input. The modifier reads the state
    /// itself, so a tick of the ease re-runs this body and nothing above it.
    func containerHeight(_ state: ChatListItemState, onMeasure: @escaping (CGFloat) -> Void) -> some View {
        modifier(ContainerHeight(state: state, onMeasure: onMeasure))
    }
}

private struct ContainerHeight: ViewModifier {
    let state: ChatListItemState
    let onMeasure: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                onMeasure(measured)
            }
            .frame(height: state.containerHeight, alignment: .top)
            // A shape rather than a conditional `.clipped()`, so toggling
            // never restructures the chain and remounts the content.
            .clipShape(OverflowClip(allowsOverflow: !state.clipsContent))
    }
}

/// The view's own bounds, or those bounds extended far enough downward that
/// nothing below them is clipped.
private struct OverflowClip: Shape {
    let allowsOverflow: Bool

    func path(in rect: CGRect) -> Path {
        var clip = rect
        if allowsOverflow { clip.size.height += 100_000 }
        return Path(clip)
    }
}
