import Foundation

/// Widths and spacing, resolved against the current font size.
///
/// The column widths scale with the type so the two keep their proportion as
/// the text grows: a reader who enlarges the font gets a wider column, not a
/// narrower one measured in the same points.
struct Dimensions {
    /// A readable column of roughly 80 characters, at ~0.5em average glyph
    /// advance for a proportional font.
    let contentWidth: CGFloat

    /// Room for what doesn't fit prose measure — code blocks, tables, the
    /// plan panel.
    let bleedWidth: CGFloat

    /// Empty space below the last message, roughly 4-5 lines tall, so the
    /// bottom of the conversation is visually obvious rather than butting
    /// against the composer.
    let listBottomPadding: CGFloat

    /// The gutter between a bleed item's column and the window edge.
    let horizontalGutter: CGFloat = 16

    /// How far content steps in from the bleed column around it. Keeps the
    /// two distinguishable when the window is too narrow for either to reach
    /// its maximum width.
    let contentInset: CGFloat = 12

    /// Vertical breathing room around a list item.
    let verticalPadding: CGFloat = 16

    /// The gap between the composer panel and the pane's bottom edge. Its
    /// horizontal inset comes from the content column instead, so the panel
    /// wraps at the same measure as the prose above it.
    let panelInset: CGFloat = 10

    /// The floating composer panel's corner radius. Every other radius in the
    /// panel derives from this one through `ComposerPanelMetrics`.
    let panelCornerRadius: CGFloat = 18

    /// The standard content rhythm within the panel: spacing between rows
    /// (the autocomplete popup, the composer, the statusline), and inset
    /// within a row (the plan dock bar, the slash-command popup's own rows,
    /// the controls row's items).
    let panelContentInset: CGFloat = 8

    /// The composer's inset from the glass panel's edge, on every side —
    /// shared by its text, its control strip, and the queued-messages strip
    /// that floats above them. Also what `composerFieldCornerRadius` cuts
    /// concentric to.
    let composerFieldInset: CGFloat = 14

    /// The height the composer's control segments share with the send and
    /// stop circles.
    let composerControlHeight: CGFloat = 22

    /// The radius for a box floating over the composer at its own inset —
    /// the queued-messages strip and the slash-command popup — concentric
    /// with the panel holding them.
    var composerFieldCornerRadius: CGFloat {
        ComposerPanelMetrics.concentricRadius(outer: panelCornerRadius, inset: composerFieldInset)
    }

    /// Gap between blocks within one message — paragraph to paragraph, prose
    /// to code.
    let blockSpacing: CGFloat

    /// Gap between two messages in the chat list. The rows themselves carry
    /// no vertical inset, so this is the whole of it.
    let messageSpacing: CGFloat = 40

    /// Gap between two blocks of one message — prose to a tool call, a tool
    /// call to the turn in flight.
    let messageBlockSpacing: CGFloat = 8

    /// Gap between consecutive tool calls, whether they sit in one message or
    /// in a run of messages. Tight enough that a run reads as one list.
    let toolCallSpacing: CGFloat = 4

    private let bodySize: CGFloat

    init(bodySize: CGFloat) {
        self.bodySize = bodySize
        contentWidth = bodySize * 40
        bleedWidth = bodySize * 50
        listBottomPadding = bodySize * 4.5
        blockSpacing = bodySize * 1.15
    }

    /// Extra space above a heading, on top of `blockSpacing`. A heading
    /// belongs to the text below it, so the space goes above only, and it
    /// tapers with the level: an h1 opens a section, an h5 barely interrupts.
    func headingTopSpacing(level: Int) -> CGFloat {
        let multiplier: CGFloat = switch level {
        case 1: 1.4
        case 2: 1.0
        case 3: 0.65
        case 4: 0.35
        default: 0
        }
        return bodySize * multiplier
    }

    /// Between one statusline segment and the next. Wider than the panel's
    /// own rhythm because each segment is two stacked lines, and a tighter
    /// gap would read as one column.
    let statuslineSegmentSpacing: CGFloat = 14

    /// Between a meter's reading and its bar.
    let statuslineMeterSpacing: CGFloat = 3

    /// Above and below the statusline row, which carries two lines per
    /// segment rather than one.
    let statuslineVerticalPadding: CGFloat = 6

    /// Between the meters and Remote Control's antenna — wider than
    /// `panelContentInset` so the antenna doesn't read as one more segment of
    /// the group it's actually reporting on.
    let statuslineTrailingGap: CGFloat = 16
}
