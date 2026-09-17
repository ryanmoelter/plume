import CoreGraphics

/// How much space to add to the left of the chat list so the minimap's
/// column on the right does not shift the text off center.
enum ChatContentBalance {
    /// The left inset to place before the chat list.
    ///
    /// Below `contentWidth` there is no room to spare and the text already
    /// fills the viewport, so this is zero. Above `contentWidth + minimapWidth
    /// * 2` there is more than enough room for the minimap's column on both
    /// sides, so this holds at `minimapWidth` and the content sits truly
    /// centered. Between those, it tracks half of whatever space is beyond
    /// `contentWidth`, so the text's left edge stays put while the space
    /// between it and the window edge grows evenly on both sides.
    static func leftInset(
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        minimapWidth: CGFloat
    ) -> CGFloat {
        let raw = (viewportWidth - contentWidth) / 2
        return min(max(raw, 0), minimapWidth)
    }
}
