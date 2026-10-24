import SwiftUI

/// Grows its content from zero height while fading it in. The content stays
/// mounted so the surrounding layout, and a popover sized to it, changes
/// height continuously instead of in one step.
///
/// A collapsed reveal takes exactly zero space. Put any gap above the content
/// inside it, as padding, so the gap grows with the reveal; keep the parent
/// stack's spacing at 0 around it.
struct Reveal<Content: View>: View, Animatable {
    var progress: Double
    @ViewBuilder var content: Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        RevealLayout(progress: progress) {
            content
                .opacity(RevealMath.opacity(progress: progress))
                .allowsHitTesting(progress > 0.5)
                .accessibilityHidden(progress == 0)
        }
        .clipped()
    }
}

enum RevealMath {
    static func height(natural: CGFloat, progress: Double) -> CGFloat {
        natural * CGFloat(min(max(progress, 0), 1))
    }

    /// Zero through the first 40% of the reveal, so content never shows while
    /// clipped thin, then eases to fully opaque.
    static func opacity(progress: Double) -> Double {
        let t = min(max((progress - 0.4) / 0.6, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

private struct RevealLayout: Layout {
    var progress: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: RevealMath.height(natural: natural.height, progress: progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: .init(width: bounds.width, height: nil)
        )
    }
}
