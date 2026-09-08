import SwiftUI

extension View {
    /// Eases this view between heights instead of jumping to a new one.
    ///
    /// `initialHeight` is where the view starts before it has measured
    /// itself. Nil is its natural height, so it arrives at its size; `0`
    /// makes it grow into place, which is what pushes the views below it.
    func animatedHeight(
        _ animation: Animation = .easeOut(duration: 0.2),
        alignment: Alignment = .top,
        initialHeight: CGFloat? = nil,
        enabled: Bool = true
    ) -> some View {
        modifier(AnimatedHeight(
            animation: animation,
            alignment: alignment,
            initialHeight: initialHeight,
            enabled: enabled
        ))
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
    let initialHeight: CGFloat?
    let enabled: Bool

    /// Nil until the first measurement, which `initialHeight` decides how to
    /// take. A row the lazy stack recycles back in mounts with fresh state,
    /// so without an initial height it arrives at its size rather than
    /// growing into it.
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        if enabled {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    guard height != nil else {
                        withAnimation(isAppearing ? animation : nil) { height = measured }
                        return
                    }
                    withAnimation(animation) { height = measured }
                }
                // Fades in with the growth: the content would otherwise be
                // fully legible while its frame is still near zero.
                .opacity(isAppearing ? 0 : 1)
                .frame(height: height ?? initialHeight, alignment: alignment)
                // Unconditional, so the setting or a row's appearing state
                // can never restructure the chain and remount the content
                // underneath it — which would collapse every open disclosure.
                .clipped()
        } else {
            content
        }
    }

    /// Before the first measurement, with somewhere to grow from.
    private var isAppearing: Bool { height == nil && initialHeight != nil }
}
