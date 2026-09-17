import CoreGraphics

/// How much space to add to the left of the chat list so its text lines up
/// with the composer below it.
enum ChatContentBalance {
    /// The left inset to place before the chat list.
    ///
    /// The composer panel sits outside the list's row and reserves nothing for
    /// the minimap, so it centers in the whole viewport. A chat row centers in
    /// what is left of the viewport once the minimap takes its column, which
    /// pulls the row half the minimap's width to the left. Matching that
    /// column on the left cancels the pull exactly, and the two line up.
    ///
    /// Once the viewport is too narrow to seat `contentWidth` beside the
    /// minimap, the row fills its span and the edges cannot line up — the
    /// minimap keeps its column there rather than the text keeping its
    /// alignment.
    static func leftInset(
        viewportWidth: CGFloat,
        contentWidth: CGFloat,
        minimapWidth: CGFloat
    ) -> CGFloat {
        min(max(viewportWidth - minimapWidth - contentWidth, 0), minimapWidth)
    }
}
