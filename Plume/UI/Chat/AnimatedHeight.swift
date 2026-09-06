import SwiftUI

extension View {
    /// Eases this view between heights instead of jumping to a new one.
    func animatedHeight(
        _ animation: Animation = .easeOut(duration: 0.2),
        alignment: Alignment = .top,
        enabled: Bool = true
    ) -> some View {
        modifier(AnimatedHeight(animation: animation, alignment: alignment, enabled: enabled))
    }
}

/// Measures the view's natural height and drives an explicit frame from it, so
/// a change in content eases rather than jumps.
///
/// The measurement is taken inside `fixedSize`, which proposes nil height to
/// the content, so what is measured is the ideal height and never the animated
/// frame — the frame cannot feed back into its own input.
private struct AnimatedHeight: ViewModifier {
    let animation: Animation
    let alignment: Alignment
    let enabled: Bool

    /// Nil until the first measurement, which is assigned without animating.
    /// A row the lazy stack recycles back in mounts with fresh state, so it
    /// arrives at its size rather than growing into it.
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        if enabled {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    guard height != nil else {
                        height = measured
                        return
                    }
                    withAnimation(animation) { height = measured }
                }
                .frame(height: height, alignment: alignment)
        } else {
            content
        }
    }
}
