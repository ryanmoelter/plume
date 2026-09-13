import SwiftUI

/// What the custom chat list tells one hosted item, mutated from outside the
/// SwiftUI root so a height ease never replaces the root view.
@MainActor
@Observable
final class ChatListItemState {
    /// The height the container is drawing this item at. Nil draws the
    /// natural height, which is what the list uses with motion turned off.
    var containerHeight: CGFloat?
    /// Set for a stream block that should type from nothing.
    var typesFromZero = false

    init(containerHeight: CGFloat? = nil, typesFromZero: Bool = false) {
        self.containerHeight = containerHeight
        self.typesFromZero = typesFromZero
    }
}

extension View {
    /// Draws this view at a height the container chose, reporting its natural
    /// height so the container can choose again.
    ///
    /// The measurement is taken inside `fixedSize`, so it is the ideal height
    /// and never the frame this modifier applies — the container's choice
    /// cannot feed back into its own input.
    func containerHeight(_ height: CGFloat?, onMeasure: @escaping (CGFloat) -> Void) -> some View {
        modifier(ContainerHeight(height: height, onMeasure: onMeasure))
    }
}

private struct ContainerHeight: ViewModifier {
    let height: CGFloat?
    let onMeasure: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                onMeasure(measured)
            }
            .frame(height: height, alignment: .top)
            .clipped()
    }
}
