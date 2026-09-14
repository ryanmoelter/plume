import AppKit

/// The chip, code-box and quote-bar geometry the composer paints behind its
/// text, computed from the TextKit 2 layout of a live `NSTextView`.
///
/// Geometry and drawing are separate so the rects can be asserted without a
/// graphics context: `rects(in:style:)` is pure, `draw(in:style:dirtyRect:)`
/// fills them. Every rect is in the text view's own coordinates — segment and
/// fragment frames come out in text-container space, and this adds
/// `textContainerOrigin`.
@MainActor
enum ComposerDecorations {
    struct Decorations: Equatable {
        var chips: [NSRect] = []
        var codeBoxes: [NSRect] = []
        var quoteBars: [NSRect] = []
    }

    /// Fills the decorations behind the text. Called from the text view's
    /// `drawBackground(in:)`, which runs before the glyphs.
    static func draw(in textView: NSTextView, style: ComposerTextStyle, dirtyRect: NSRect) {
        let decorations = rects(in: textView, style: style)
        guard !decorations.chips.isEmpty || !decorations.codeBoxes.isEmpty || !decorations.quoteBars.isEmpty else {
            return
        }

        style.codeBackground.setFill()
        for box in decorations.codeBoxes where box.intersects(dirtyRect) {
            NSBezierPath(roundedRect: box, xRadius: style.codeBoxCornerRadius, yRadius: style.codeBoxCornerRadius).fill()
        }
        for chip in decorations.chips where chip.intersects(dirtyRect) {
            NSBezierPath(roundedRect: chip, xRadius: style.chipCornerRadius, yRadius: style.chipCornerRadius).fill()
        }

        style.quoteBar.setFill()
        let barRadius = style.quoteBarWidth / 2
        for bar in decorations.quoteBars where bar.intersects(dirtyRect) {
            NSBezierPath(roundedRect: bar, xRadius: barRadius, yRadius: barRadius).fill()
        }
    }

    static func rects(in textView: NSTextView, style: ComposerTextStyle) -> Decorations {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage,
              storage.length > 0
        else { return Decorations() }

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let origin = textView.textContainerOrigin
        let context = Context(
            textView: textView,
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            storage: storage,
            origin: origin,
            style: style
        )

        var decorations = Decorations()
        decorations.chips = chipRects(context)
        let (boxes, bars) = blockRects(context)
        decorations.codeBoxes = boxes
        decorations.quoteBars = bars
        return decorations
    }

    // MARK: - Shared state

    private struct Context {
        let textView: NSTextView
        let layoutManager: NSTextLayoutManager
        let contentStorage: NSTextContentStorage
        let storage: NSTextStorage
        let origin: NSPoint
        let style: ComposerTextStyle

        /// The container's full drawing width in view coordinates. A code box
        /// spans this rather than the fragments' used width, so short lines
        /// don't make a ragged box.
        var containerRect: (x: CGFloat, width: CGFloat) {
            let width = textView.textContainer?.size.width ?? textView.bounds.width
            return (origin.x, width > 0 ? width : textView.bounds.width)
        }
    }

    // MARK: - Inline code chips

    /// One rounded rect per line a code span occupies.
    ///
    /// The leading edge always reclaims `chipPadding`, matching the chat's
    /// `CodeChipRenderer`: the kern the storage carries on the character
    /// *before* the span opens a gap that sits outside the span's own segment
    /// frame. A trailing kern on the span's last character is already inside
    /// that frame, so the trailing edge only extends when the storage carries
    /// no kern there.
    private static func chipRects(_ context: Context) -> [NSRect] {
        var rects: [NSRect] = []
        for range in ComposerCodeRanges.inlineCodeSpans(in: context.storage) {
            let trailingKern = (context.storage.attribute(
                .kern, at: NSMaxRange(range) - 1, effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0
            let trailingPad = trailingKern > 0 ? 0 : context.style.chipPadding
            let minX = context.containerRect.x

            let frames = segmentFrames(for: range, context)
            for frame in frames {
                var rect = frame
                rect.origin.x = max(minX, rect.origin.x - context.style.chipPadding)
                rect.size.width = frame.maxX + trailingPad - rect.origin.x
                rects.append(rect)
            }
        }
        return merged(rects)
    }

    /// Unions rects that sit on the same line and touch, so one span never
    /// paints two chips with a seam between them.
    private static func merged(_ rects: [NSRect]) -> [NSRect] {
        var result: [NSRect] = []
        for rect in rects.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            if let last = result.last, abs(last.minY - rect.minY) < 0.5, rect.minX <= last.maxX + 0.5 {
                result[result.count - 1] = last.union(rect)
            } else {
                result.append(rect)
            }
        }
        return result
    }

    private static func segmentFrames(for range: NSRange, _ context: Context) -> [NSRect] {
        guard let textRange = textRange(range, in: context.contentStorage) else { return [] }
        var frames: [NSRect] = []
        context.layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            if frame.width > 0, frame.height > 0 {
                frames.append(frame.offsetBy(dx: context.origin.x, dy: context.origin.y))
            }
            return true
        }
        return frames
    }

    // MARK: - Code boxes and quote bars

    /// Walks paragraphs once, grouping consecutive ones that share a
    /// decoration: code paragraphs with the same `blockID` make one box, and
    /// consecutive quote paragraphs one bar.
    private static func blockRects(_ context: Context) -> (boxes: [NSRect], bars: [NSRect]) {
        var boxes: [NSRect] = []
        var bars: [NSRect] = []
        let ns = context.storage.string as NSString
        let (containerX, containerWidth) = context.containerRect

        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let kind = context.storage.attribute(.plumeBlock, at: paragraph.location, effectiveRange: nil) as? ComposerBlockKind

            guard let kind, isDecorated(kind) else {
                location = NSMaxRange(paragraph)
                continue
            }

            var group = paragraph
            var next = NSMaxRange(paragraph)
            while next < ns.length {
                let following = ns.paragraphRange(for: NSRange(location: next, length: 0))
                let followingKind = context.storage.attribute(.plumeBlock, at: following.location, effectiveRange: nil) as? ComposerBlockKind
                guard let followingKind, continues(kind, followingKind) else { break }
                group = NSUnionRange(group, following)
                next = NSMaxRange(following)
            }
            location = next

            guard let bounds = fragmentBounds(for: group, context) else { continue }
            if case .codeBlock = kind.kind {
                boxes.append(NSRect(
                    x: containerX,
                    y: bounds.minY,
                    width: containerWidth,
                    height: bounds.height
                ))
            } else {
                bars.append(NSRect(
                    x: containerX,
                    y: bounds.minY,
                    width: context.style.quoteBarWidth,
                    height: bounds.height
                ))
            }
        }
        return (boxes, bars)
    }

    private static func isDecorated(_ kind: ComposerBlockKind) -> Bool {
        switch kind.kind {
        case .codeBlock, .quote: true
        default: false
        }
    }

    private static func continues(_ kind: ComposerBlockKind, _ next: ComposerBlockKind) -> Bool {
        switch (kind.kind, next.kind) {
        case (.quote, .quote): true
        case (.codeBlock, .codeBlock): kind.blockID == next.blockID
        default: false
        }
    }

    /// The union of the layout fragments covering `range`, in view
    /// coordinates. Uses `layoutFragmentFrame` rather than the segment frames
    /// because a fragment frame includes the paragraph spacing
    /// `ComposerTextStyle.paragraphStyle` puts before and after a code block,
    /// which is the box's vertical padding — no extra inset, so two blocks
    /// back to back stay two boxes rather than overlapping into one. TextKit
    /// drops that spacing at the document's first and last paragraph, where a
    /// box therefore sits tight against its text.
    private static func fragmentBounds(for range: NSRange, _ context: Context) -> NSRect? {
        guard let textRange = textRange(range, in: context.contentStorage) else { return nil }
        var bounds: NSRect?
        context.layoutManager.enumerateTextLayoutFragments(
            from: textRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard fragment.rangeInElement.location.compare(textRange.endLocation) == .orderedAscending else {
                return false
            }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: context.origin.x, dy: context.origin.y)
            bounds = bounds.map { $0.union(frame) } ?? frame
            return true
        }
        return bounds
    }

    // MARK: - Range conversion

    private static func textRange(_ range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
