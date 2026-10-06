import SwiftUI

/// The newest `/btw` exchange, below the chat and above the composer.
///
/// A side question answers out of band and writes nothing to the transcript,
/// so without this there is nothing on screen between asking and reading the
/// panel — the question looks ignored.
///
/// Drawn as a second composer panel — same glass, radius, width and inset —
/// so the question lines up with the text being written below it. The answer
/// is the agent speaking, so it takes the chat's prose face and size.
struct SideQuestionChip: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.chatFontSize) private var chatFontSize

    let exchange: SideQuestion
    let glass: Glass
    /// The tallest the whole panel may grow. The answer scrolls within
    /// whatever the header and question leave of it.
    let maxHeight: CGFloat
    let onOpenPanel: () -> Void
    let onDismiss: () -> Void

    @State private var answerOverflow = ScrollOverflow()
    @State private var promptHeight: CGFloat = 0

    static let symbol = "bubble.left.and.bubble.right"

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                header
                question
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { promptHeight = $0 }
            answer
        }
        .padding([.top, .horizontal], dimensions.composerFieldInset)
        // An answer carries the bottom inset inside its scroll view instead,
        // so it scrolls right up to the card's edge.
        .padding(.bottom, hasAnswer ? 0 : dimensions.composerFieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(glass, in: .rect(cornerRadius: dimensions.panelCornerRadius))
        .plumeTheme(bodySize: chatFontSize)
        .plumeID(AccessibilityID.sideQuestionChip, value: chipValue)
    }

    /// Titled the way a decision card is, so it reads as the same family as
    /// a question the agent asks.
    private var header: some View {
        HStack(spacing: DecisionCard.rowSpacing) {
            Label("/btw", systemImage: Self.symbol)
                .font(typography.caption.semibold)
                .emphasis(.secondary)
            status
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this side question")
            .accessibilityLabel("Dismiss side question")
            .plumeID(AccessibilityID.sideQuestionChipDismiss, invoke: onDismiss)
        }
    }

    private var question: some View {
        Text(exchange.question)
            .font(typography.body.font)
            .lineSpacing(typography.body.lineSpacing)
            .lineLimit(questionLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch exchange.state {
        case .pending, .running:
            WorkingEllipsis(color: colors.activity)
                .font(typography.caption.font)
        case .answered:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(typography.caption.font)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var answer: some View {
        switch exchange.state {
        case .pending, .running:
            EmptyView()
        case let .answered(answer):
            scrolling {
                MarkdownView(answer, isAgentVoice: true)
                    // Each block pads itself off the chat list's edges, which
                    // would indent the answer from the question above it.
                    .padding(.horizontal, -dimensions.horizontalEdgePadding)
            }
        case let .failed(message):
            scrolling {
                Text(message)
                    .font(typography.body.font)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The answer scrolls rather than growing without limit, so a long one
    /// cannot push the composer off the window. Capped in height rather than
    /// in lines: a short answer takes only the room it needs.
    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, answerTopPadding)
                .padding(.bottom, answerBottomPadding)
        }
        .onScrollGeometryChange(for: ScrollOverflow.self) { geometry in
            ScrollOverflow(visibleRect: geometry.visibleRect, contentHeight: geometry.contentSize.height)
        } action: { _, overflow in
            withAnimation(.easeOut(duration: 0.15)) { answerOverflow = overflow }
        }
        .mask(edgeFade)
        .frame(maxHeight: answerMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture(perform: onOpenPanel)
    }

    /// Fades only the edges with more answer past them, so a cut-off answer
    /// reads as scrollable without the glass behind it changing.
    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: answerOverflow.above ? edgeFadeHeight : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: answerOverflow.below ? edgeFadeHeight : 0)
        }
    }

    private let questionLineLimit = 2
    private let sectionSpacing: CGFloat = 6
    /// Inside the scroll view, so the first line clears the top fade once
    /// the answer is scrolled.
    private let answerTopPadding: CGFloat = 10
    /// Deeper than the card's own inset, so the end of a scrolled answer
    /// reads as the end rather than a line cut off at the edge.
    private let answerBottomPadding: CGFloat = 28
    /// A floor, so a tiny window still shows a few lines of answer.
    private let answerMinHeight: CGFloat = 80

    private var answerMaxHeight: CGFloat {
        let chrome = promptHeight + sectionSpacing + dimensions.composerFieldInset
        return max(answerMinHeight, maxHeight - chrome)
    }
    private let edgeFadeHeight: CGFloat = 28

    private var hasAnswer: Bool {
        switch exchange.state {
        case .pending, .running: false
        case .answered, .failed: true
        }
    }

    /// What a driver reads to tell the states apart without the glyph.
    private var chipValue: String {
        switch exchange.state {
        case .pending, .running: "running"
        case let .answered(answer): answer
        case let .failed(message): "failed: \(message)"
        }
    }
}

/// Which edges of a scroll view have content past them.
struct ScrollOverflow: Equatable {
    var above = false
    var below = false

    /// The half-point tolerance absorbs rounding at rest, which would
    /// otherwise leave a fade on an answer scrolled fully to an end.
    init(visibleRect: CGRect, contentHeight: CGFloat) {
        above = visibleRect.minY > 0.5
        below = visibleRect.maxY < contentHeight - 0.5
    }

    init() {}
}
