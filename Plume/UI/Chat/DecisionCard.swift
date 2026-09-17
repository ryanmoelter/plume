import SwiftUI

/// The shared look of everything in the transcript that asks the user to
/// decide: a permission request, an `AskUserQuestion`, and the plan overlay's
/// feedback field.
///
/// They are one family because they occupy the same place in the
/// conversation and demand the same thing. What legitimately differs between
/// them is the *subject* — a permission is a tool about to run, a question is
/// the agent asking — which shows as the accent hue, and nothing else.
enum DecisionCard {
    /// The gap between a card's stacked sections.
    static let sectionSpacing: CGFloat = 10
    /// The gap between lines within one section.
    static let rowSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 12
    /// Inset and radius for a box nested inside a card — an option row, the
    /// input-field scroller, a text field.
    static let nestedRadius: CGFloat = 6
    static let nestedPadding: CGFloat = 8
}

/// A card's accent, which says what is being decided.
enum DecisionSubject {
    /// A tool call, or a plan whose approval sets work going.
    case consequential
    /// The agent asking, which changes nothing on its own.
    case inquiry

    func hue(in colors: Palette) -> Color {
        switch self {
        case .consequential: colors.warning
        case .inquiry: colors.attention
        }
    }
}

extension View {
    /// The card container every decision surface shares. `subject` is nil for
    /// a settled card, which carries no accent because nothing is being asked.
    func decisionCard(subject: DecisionSubject?, colors: Palette) -> some View {
        padding(DecisionCard.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceTint, in: .rect(cornerRadius: DecisionCard.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DecisionCard.cornerRadius)
                    .strokeBorder(
                        subject.map { $0.hue(in: colors).emphasized(.disabled, in: colors) }
                            ?? colors.divider,
                        lineWidth: 1
                    )
            }
    }

    /// The treatment for a field the user types a decision into — a denial
    /// reason, a typed answer, plan feedback. Bordered in the selection color
    /// once it holds something, so a typed answer reads as chosen the way a
    /// picked option does.
    func decisionField(isFilled: Bool, colors: Palette) -> some View {
        padding(DecisionCard.nestedPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceTint, in: .rect(cornerRadius: DecisionCard.nestedRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DecisionCard.nestedRadius)
                    .strokeBorder(
                        isFilled ? colors.selection : colors.divider,
                        lineWidth: isFilled ? 1.5 : 1
                    )
            }
    }
}

/// A card's title line: what is being decided, in the subject's hue.
struct DecisionCardHeader: View, ThemedView {
    @Environment(\.theme) var theme

    let title: String
    let symbol: String
    /// Nil for a settled card, which states its subject in the past tense and
    /// needs no accent.
    let subject: DecisionSubject?
    /// An aside after the title, such as which agent asked.
    var trailing: (text: String, symbol: String)?

    var body: some View {
        HStack(spacing: DecisionCard.rowSpacing) {
            Label(title, systemImage: symbol)
                .font(typography.caption.semibold)
                .foregroundStyle(AnyShapeStyle.role(
                    subject?.hue(in: colors) ?? colors.divider,
                    when: subject != nil,
                    otherwise: .secondary
                ))
            if let trailing {
                Label(trailing.text, systemImage: trailing.symbol)
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
        }
        .chatTextColumn()
    }
}
