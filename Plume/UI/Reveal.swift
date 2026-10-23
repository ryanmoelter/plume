import SwiftUI

/// Grows its content from zero height while fading it in. The content stays
/// mounted so the surrounding layout, and a popover sized to it, changes
/// height continuously instead of in one step.
///
/// Place it in a `VStack` whose spacing is `spacing`. The layout cancels the
/// stack's leading gap while collapsed.
struct Reveal<Content: View>: View, Animatable {
    var progress: Double
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        RevealLayout(progress: progress, spacing: spacing) {
            content
                .opacity(progress)
                .allowsHitTesting(progress > 0.5)
                .accessibilityHidden(progress == 0)
        }
        .padding(.top, -spacing)
        .clipped()
    }
}

private struct RevealLayout: Layout {
    var progress: Double
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: (natural.height + spacing) * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + spacing * progress),
            anchor: .topLeading,
            proposal: .init(width: bounds.width, height: nil)
        )
    }
}
