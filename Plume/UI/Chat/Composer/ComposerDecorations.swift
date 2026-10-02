import AppKit

/// The chip, code-box, quote-bar, rule and list-marker geometry the composer
/// paints behind its text, computed from the TextKit 2 layout of a live
/// `NSTextView`.
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
        var rules: [NSRect] = []
        /// Where the marker of a list item on the character-less last line
        /// is drawn from: the origin of `ComposerListMarkerLayout`'s fragment.
        var trailingListMarker: NSPoint?
    }

    /// Fills the decorations behind the text. Called from the text view's
    /// `drawBackground(in:)`, which runs before the glyphs.
    static func draw(in textView: NSTextView, style: ComposerTextStyle, dirtyRect: NSRect) {
        let decorations = rects(in: textView, style: style)
        guard decorations != Decorations() else { return }

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

        style.rule.setFill()
        for rule in decorations.rules where rule.intersects(dirtyRect) {
            rule.fill()
        }

        if let point = decorations.trailingListMarker,
           let composer = textView as? ComposerNSTextView,
           let kind = composer.trailingLineKind,
           let marker = composer.trailingListMarker(for: kind),
           let context = NSGraphicsContext.current?.cgContext {
            marker.fragment.draw(at: point, in: context)
        }
    }

    static func rects(in textView: NSTextView, style: ComposerTextStyle) -> Decorations {
        let composer = textView as? ComposerNSTextView
        let trailingKind = composer?.trailingLineKind
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage,
              storage.length > 0 || trailingKind != nil
        else { return Decorations() }

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let origin = textView.textContainerOrigin
        let trailingLine = trailingKind.flatMap { kind in
            trailingLineRect(layoutManager, origin: origin).map { (kind: kind, rect: $0) }
        }
        let context = Context(
            textView: textView,
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            storage: storage,
            origin: origin,
            style: style,
            trailingLine: trailingLine
        )

        var decorations = Decorations()
        decorations.chips = chipRects(context)
        let (boxes, bars) = blockRects(context)
        decorations.codeBoxes = boxes
        decorations.quoteBars = bars
        decorations.rules = ruleRects(context)
        if let trailingLine, let marker = composer?.trailingListMarker(for: trailingLine.kind) {
            decorations.trailingListMarker = NSPoint(
                x: origin.x + marker.lineOffset.x,
                y: trailingLine.rect.minY + marker.lineOffset.y
            )
        }
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
        /// The character-less last line's kind, and its line's typographic
        /// bounds in view coordinates.
        let trailingLine: (kind: ComposerBlockKind, rect: NSRect)?

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

    /// Groups consecutive paragraphs that share a decoration: code paragraphs
    /// with the same `blockID` make one box, and consecutive quote paragraphs
    /// one bar.
    ///
    /// The character-less last line lays out inside the last paragraph's
    /// fragment. It joins that paragraph's box or bar when its kind shares the
    /// decoration, gets one of its own when only it is decorated, and is cut
    /// off the paragraph's otherwise.
    private static func blockRects(_ context: Context) -> (boxes: [NSRect], bars: [NSRect]) {
        var boxes: [NSRect] = []
        var bars: [NSRect] = []
        let (containerX, containerWidth) = context.containerRect

        func append(_ kind: ComposerBlockKind, minY: CGFloat, maxY: CGFloat) {
            if case .codeBlock = kind.kind {
                boxes.append(NSRect(x: containerX, y: minY, width: containerWidth, height: maxY - minY))
            } else {
                bars.append(NSRect(x: containerX, y: minY, width: context.style.quoteBarWidth, height: maxY - minY))
            }
        }

        let paragraphs = ComposerParagraphs.all(in: context.storage)
        let lastKind = paragraphs.last?.storedKind
        let trailingJoinsLast = context.trailingLine.map { trailing in
            lastKind.map { sharesDecoration($0, trailing.kind) } ?? false
        } ?? false

        for run in ComposerParagraphs.runs(of: paragraphs, where: sharesDecoration) {
            guard let first = run.first, let last = run.last, let kind = first.storedKind, isDecorated(kind),
                  let bounds = fragmentBounds(for: NSUnionRange(first.range, last.range), context)
            else { continue }
            var maxY = bounds.maxY
            if let trailing = context.trailingLine, NSMaxRange(last.range) == context.storage.length, !trailingJoinsLast {
                maxY = min(maxY, trailing.rect.minY)
            }
            append(kind, minY: bounds.minY, maxY: maxY)
        }

        if let trailing = context.trailingLine, isDecorated(trailing.kind), !trailingJoinsLast {
            append(trailing.kind, minY: trailing.rect.minY, maxY: trailing.rect.maxY)
        }
        return (boxes, bars)
    }

    private static func isDecorated(_ kind: ComposerBlockKind) -> Bool {
        switch kind.kind {
        case .codeBlock, .quote: true
        default: false
        }
    }

    private nonisolated static func sharesDecoration(_ previous: ComposerParagraph, _ next: ComposerParagraph) -> Bool {
        guard let kind = previous.storedKind, let nextKind = next.storedKind else { return false }
        return sharesDecoration(kind, nextKind)
    }

    private nonisolated static func sharesDecoration(_ kind: ComposerBlockKind, _ nextKind: ComposerBlockKind) -> Bool {
        switch (kind.kind, nextKind.kind) {
        case (.quote, .quote): return true
        case (.codeBlock, .codeBlock): return kind.blockID == nextKind.blockID
        default: return false
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

    /// The typographic bounds of the character-less last line, in view
    /// coordinates. It is the last line of the last fragment, or the only
    /// line of an empty document's.
    private static func trailingLineRect(_ layoutManager: NSTextLayoutManager, origin: NSPoint) -> NSRect? {
        var rect: NSRect?
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.endLocation,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            if let line = fragment.textLineFragments.last {
                let frame = fragment.layoutFragmentFrame
                rect = line.typographicBounds.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
            }
            return false
        }
        return rect
    }

    // MARK: - Rules

    /// One line across the text column per `.rule` paragraph, through the
    /// middle of the paragraph's empty line.
    private static func ruleRects(_ context: Context) -> [NSRect] {
        let padding = context.textView.textContainer?.lineFragmentPadding ?? 0
        let (containerX, containerWidth) = context.containerRect
        let thickness = context.style.ruleThickness
        return ComposerParagraphs.all(in: context.storage)
            .filter { $0.storedKind?.kind == .rule }
            .compactMap { paragraph in
                guard let line = firstLineRect(for: paragraph.range, context) else { return nil }
                return NSRect(
                    x: containerX + padding,
                    y: (line.midY - thickness / 2).rounded(),
                    width: containerWidth - padding * 2,
                    height: thickness
                )
            }
    }

    /// The typographic bounds of the first line `range` lays out, in view
    /// coordinates. Unlike the fragment frame, this leaves out the
    /// paragraph's spacing.
    private static func firstLineRect(for range: NSRange, _ context: Context) -> NSRect? {
        guard let textRange = textRange(range, in: context.contentStorage),
              let fragment = context.layoutManager.textLayoutFragment(for: textRange.location),
              let line = fragment.textLineFragments.first
        else { return nil }
        let frame = fragment.layoutFragmentFrame
        return line.typographicBounds.offsetBy(
            dx: frame.minX + context.origin.x,
            dy: frame.minY + context.origin.y
        )
    }

    // MARK: - Range conversion

    private static func textRange(_ range: NSRange, in contentStorage: NSTextContentStorage) -> NSTextRange? {
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
