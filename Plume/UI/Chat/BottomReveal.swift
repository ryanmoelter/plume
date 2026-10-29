import SwiftUI

extension View {
    /// Shows the view through a clip anchored to its bottom edge, so only
    /// the top edge moves as it opens, closes or changes height. The content
    /// stays put as long as its own changes arrive unanimated; only the clip
    /// eases.
    ///
    /// `overhang` is how far the content draws past its own frame, which the
    /// clip leaves visible. `onHidden` runs once a close has finished, so the
    /// caller can drop content it kept on screen for the close.
    func bottomReveal(
        isRevealed: Bool,
        overhang: EdgeInsets = EdgeInsets(),
        animation: Animation,
        onHidden: @escaping () -> Void = {}
    ) -> some View {
        modifier(BottomReveal(isRevealed: isRevealed, overhang: overhang, animation: animation, onHidden: onHidden))
    }
}

/// Measured inside `fixedSize`, like `AnimatedHeight`, so the animated frame
/// never feeds back into the height it animates toward.
private struct BottomReveal: ViewModifier {
    let isRevealed: Bool
    let overhang: EdgeInsets
    let animation: Animation
    let onHidden: () -> Void

    @State private var naturalHeight: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                naturalHeight = measured
                guard isShown, measured != height else { return }
                withAnimation(animation) { height = measured }
            }
            .frame(height: height, alignment: .bottom)
            .mask(alignment: .bottom) {
                Rectangle().padding(EdgeInsets(
                    top: -overhang.top,
                    leading: -overhang.leading,
                    bottom: -overhang.bottom,
                    trailing: -overhang.trailing
                ))
            }
            .opacity(isShown ? 1 : 0)
            .onChange(of: isRevealed, initial: true) { _, revealed in
                withAnimation(animation) {
                    isShown = revealed
                    height = revealed ? naturalHeight : 0
                } completion: {
                    if !isShown { onHidden() }
                }
            }
    }
}
