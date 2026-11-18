import CoreGraphics
import Foundation

/// How wide the rail's bars draw and how far they sit from the pane's edge.
///
/// The rail overlays the chat rather than taking a column, so it sizes
/// itself from the room between the pane's edge and the bleed column beside
/// it. Between `collapsedWidth` and `normalWidth` it interpolates, so it
/// grows with that room rather than snapping at a threshold.
struct MinimapRailGeometry: Equatable {
    var width: CGFloat
    var inset: CGFloat

    /// What the rail draws at rest: the bars and the inset holding them off
    /// the window edge. The gap toward the chat is left out — it is empty
    /// space over the conversation, and reaching into it made the map react
    /// while the pointer was still on the text.
    var footprint: CGFloat { width + inset }

    /// The rail's narrowest width, and so a prompt bar's. This plus
    /// `collapsedInset` has to fit within the bleed padding, or the rail
    /// crosses a bleed item's column and sits over the text.
    static let collapsedWidth: CGFloat = 8
    static let collapsedInset: CGFloat = 2
    static let normalWidth: CGFloat = 16
    static let normalInset: CGFloat = 8

    /// Room left between the bars and the bleed column at full size. Nothing
    /// draws it — it is what stops the rail from crowding the conversation
    /// once both are at their full width.
    static let normalGap: CGFloat = normalInset

    static let normalCost: CGFloat = normalWidth + normalInset + normalGap

    /// The space between the pane's edge on `side` and the near edge of the
    /// bleed column. The list narrows its rows by `columnReserve` on the
    /// trailing side, which moves the column toward the leading edge.
    ///
    /// A trailing rail ignores the reserve: the info pane that makes it sits
    /// between the column and the rail, and its reserve already holds room
    /// for a rail sized from the full pane.
    static func room(side: MinimapSide, viewportWidth: CGFloat, columnReserve: CGFloat, bleedWidth: CGFloat) -> CGFloat {
        let rowWidth = side == .leading ? viewportWidth - columnReserve : viewportWidth
        return max(0, (rowWidth - bleedWidth) / 2)
    }

    /// How much of its normal size the rail can afford: 0 while the bars are
    /// still within the bleed column's padding, and 1 once they clear it with
    /// room to spare. Growth starts where the bars would otherwise reach into
    /// the padding beside a full-width bleed item, so widening the pane never
    /// costs the conversation anything.
    static func spread(room: CGFloat, bleedPadding: CGFloat) -> CGFloat {
        guard room > bleedPadding else { return 0 }
        return min((room - bleedPadding) / (normalCost - bleedPadding), 1)
    }

    init(width: CGFloat, inset: CGFloat) {
        self.width = width
        self.inset = inset
    }

    init(room: CGFloat, bleedPadding: CGFloat) {
        let spread = Self.spread(room: room, bleedPadding: bleedPadding)
        width = Self.collapsedWidth + (Self.normalWidth - Self.collapsedWidth) * spread
        inset = Self.collapsedInset + (Self.normalInset - Self.collapsedInset) * spread
    }

    /// The rail under the pointer, its bars widened `fraction` of the way to
    /// their normal width so a narrow rail is still a target. The inset stays
    /// put, so the bars grow from where they already are.
    func expanded(by fraction: CGFloat) -> MinimapRailGeometry {
        let fraction = min(max(fraction, 0), 1)
        return MinimapRailGeometry(width: width + (max(width, Self.normalWidth) - width) * fraction, inset: inset)
    }
}
