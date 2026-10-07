import AppKit

/// The chips, code boxes, quote bars, rules, bullets and checkboxes the
/// composer paints behind its text, computed from the TextKit 2 layout of a
/// live `NSTextView` and the text's `MarkdownLineStructure`.
///
/// Geometry and drawing are separate so the rects can be asserted without a
/// graphics context: `rects(in:metrics:)` is pure, `draw(_:in:metrics:)` fills
/// them. Every rect is in the text view's own coordinates.
///
/// Nothing is drawn left of the line fragment padding: the chat composer pulls
/// its text view out by that much and clips it, so anything there is invisible.
@MainActor
enum ComposerDecorations {
    struct Checkbox: Equatable {
        var rect: NSRect
        var isChecked: Bool
        /// The `[ ]` or `[x]` a click toggles.
        var box: NSRange
    }

    struct Bullet: Equatable {
        var glyph: String
        /// The left end of the glyph's baseline, which is the item text's.
        var baselineOrigin: NSPoint
    }

    struct Decorations: Equatable {
        var chips: [NSRect] = []
        var codeBoxes: [NSRect] = []
        var quoteBars: [NSRect] = []
        var rules: [NSRect] = []
        var bullets: [Bullet] = []
        var checkboxes: [Checkbox] = []
    }

    static func draw(_ decorations: Decorations, in dirtyRect: NSRect, metrics: ComposerMarkdownMetrics) {
        ComposerMarkdownMetrics.codeBackground.setFill()
        for box in decorations.codeBoxes where box.intersects(dirtyRect) {
            NSBezierPath(roundedRect: box, xRadius: metrics.codeBoxCornerRadius, yRadius: metrics.codeBoxCornerRadius).fill()
        }
        for chip in decorations.chips where chip.intersects(dirtyRect) {
            NSBezierPath(roundedRect: chip, xRadius: metrics.chipCornerRadius, yRadius: metrics.chipCornerRadius).fill()
        }

        ComposerMarkdownMetrics.quoteBar.setFill()
        let barRadius = metrics.quoteBarWidth / 2
        for bar in decorations.quoteBars where bar.intersects(dirtyRect) {
            NSBezierPath(roundedRect: bar, xRadius: barRadius, yRadius: barRadius).fill()
        }

        ComposerMarkdownMetrics.rule.setFill()
        for rule in decorations.rules where rule.intersects(dirtyRect) {
            rule.fill()
        }

        let bulletAttributes: [NSAttributedString.Key: Any] = [
            .font: metrics.body,
            .foregroundColor: NSColor.labelColor,
        ]
        for bullet in decorations.bullets {
            // Without `.usesLineFragmentOrigin`, the rect's origin is the baseline.
            (bullet.glyph as NSString).draw(
                with: NSRect(origin: bullet.baselineOrigin, size: .zero),
                options: [],
                attributes: bulletAttributes
            )
        }

        for checkbox in decorations.checkboxes where checkbox.rect.intersects(dirtyRect) {
            drawCheckbox(checkbox)
        }
    }

    private static func drawCheckbox(_ checkbox: Checkbox) {
        let rect = checkbox.rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if checkbox.isChecked {
            NSColor.controlAccentColor.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + rect.width * 0.24, y: rect.midY + rect.height * 0.02))
            check.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.maxY - rect.height * 0.26))
            check.line(to: NSPoint(x: rect.maxX - rect.width * 0.22, y: rect.minY + rect.height * 0.27))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    static func rects(in textView: NSTextView, metrics: ComposerMarkdownMetrics) -> Decorations {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage,
              storage.length > 0
        else { return Decorations() }

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let text = storage.string
        let lines = MarkdownLineStructure.lines(in: text)
        let context = Context(
            textView: textView,
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            length: storage.length,
            metrics: metrics
        )

        var decorations = Decorations()
        decorations.chips = chipRects(MarkdownHighlighter.spans(in: text, lines: lines), context)
        decorations.codeBoxes = codeBoxRects(lines, context)
        decorations.quoteBars = quoteBarRects(lines, context)
        for line in lines {
            switch line.kind {
            case .rule:
                if let rect = context.firstLineRect(of: line) {
                    decorations.rules.append(NSRect(
                        x: context.columnStart,
                        y: (rect.midY - metrics.ruleThickness / 2).rounded(),
                        width: context.columnEnd - context.columnStart,
                        height: metrics.ruleThickness
                    ))
                }
            case .bullet:
                if let baseline = context.firstBaseline(of: line) {
                    let glyph = line.depth.isMultiple(of: 2) ? "•" : "◦"
                    let width = (glyph as NSString).size(withAttributes: [.font: metrics.body]).width
                    let right = context.columnStart + metrics.contentColumn(for: line) - metrics.markerGap
                    decorations.bullets.append(Bullet(glyph: glyph, baselineOrigin: NSPoint(x: right - width, y: baseline)))
                }
            case let .task(isChecked):
                if let rect = context.firstLineRect(of: line), let box = line.checkbox {
                    let size = metrics.checkboxSize
                    let right = context.columnStart + metrics.contentColumn(for: line) - metrics.markerGap
                    let centerY = rect.minY + metrics.body.ascender - metrics.body.xHeight / 2
                    decorations.checkboxes.append(Checkbox(
                        rect: NSRect(x: right - size, y: (centerY - size / 2).rounded(), width: size, height: size),
                        isChecked: isChecked,
                        box: box
                    ))
                }
            default:
                break
            }
        }
        return decorations
    }

    // MARK: - Shared state

    private struct Context {
        let textView: NSTextView
        let layoutManager: NSTextLayoutManager
        let contentStorage: NSTextContentStorage
        let length: Int
        let metrics: ComposerMarkdownMetrics

        var origin: NSPoint { textView.textContainerOrigin }

        var lineFragmentPadding: CGFloat {
            textView.textContainer?.lineFragmentPadding ?? 0
        }

        private var containerWidth: CGFloat {
            let width = textView.textContainer?.size.width ?? textView.bounds.width
            return width > 0 ? width : textView.bounds.width
        }

        /// The leading edge of the visible text column, in view coordinates.
        var columnStart: CGFloat { origin.x + lineFragmentPadding }
        var columnEnd: CGFloat { origin.x + containerWidth - lineFragmentPadding }

        /// The typographic bounds of the first line `line` lays out, in view
        /// coordinates. The empty line after a trailing newline has no
        /// character, so it comes from the extra line fragment.
        func firstLineRect(of line: MarkdownLine) -> NSRect? {
            if line.range.location >= length {
                return trailingLineRect()
            }
            guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: line.range.location),
                  let fragment = layoutManager.textLayoutFragment(for: location),
                  let lineFragment = fragment.textLineFragments.first
            else { return nil }
            let frame = fragment.layoutFragmentFrame
            return lineFragment.typographicBounds.offsetBy(dx: frame.minX + origin.x, dy: frame.minY + origin.y)
        }

        /// The y of the first baseline `line` lays out, in view coordinates.
        func firstBaseline(of line: MarkdownLine) -> CGFloat? {
            if line.range.location >= length {
                return trailingLineRect().map { $0.minY + metrics.body.ascender }
            }
            guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: line.range.location),
                  let fragment = layoutManager.textLayoutFragment(for: location),
                  let lineFragment = fragment.textLineFragments.first
            else { return nil }
            return fragment.layoutFragmentFrame.minY + origin.y + lineFragment.typographicBounds.minY + lineFragment.glyphOrigin.y
        }

        /// The layout fragment frame of `line`, which includes its paragraph
        /// spacing.
        func fragmentRect(of line: MarkdownLine) -> NSRect? {
            if line.range.location >= length {
                return trailingLineRect()
            }
            guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: line.range.location),
                  let fragment = layoutManager.textLayoutFragment(for: location)
            else { return nil }
            return fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        }

        private func trailingLineRect() -> NSRect? {
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

        func kern(at location: Int) -> CGFloat {
            guard location >= 0, location < length else { return 0 }
            return textView.textStorage?.attribute(.kern, at: location, effectiveRange: nil) as? CGFloat ?? 0
        }

        func segmentFrames(for range: NSRange) -> [NSRect] {
            guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
                  let end = contentStorage.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return [] }
            var frames: [NSRect] = []
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
                if frame.width > 0, frame.height > 0 {
                    frames.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                }
                return true
            }
            return frames
        }
    }

    // MARK: - Inline code chips

    /// One rounded rect per line a code span occupies, reaching `chipPadding`
    /// past each backtick's glyph. TextKit 2 splits a kern's gap evenly
    /// between the segments on either side of it, so a backtick's glyph edge
    /// sits half the styler's kern inside its segment.
    private static func chipRects(_ spans: [MarkdownHighlighter.Span], _ context: Context) -> [NSRect] {
        let padding = context.metrics.chipPadding
        var rects: [NSRect] = []
        for span in spans where span.style == .inlineCode {
            var frames = context.segmentFrames(for: span.range)
            guard !frames.isEmpty else { continue }
            let leadingKern = context.kern(at: span.range.location - 1)
            let trailingKern = context.kern(at: NSMaxRange(span.range) - 1)
            let firstMinX = frames[0].minX + leadingKern / 2 - padding
            frames[0] = NSRect(x: firstMinX, y: frames[0].minY, width: frames[0].maxX - firstMinX, height: frames[0].height)
            let last = frames.count - 1
            frames[last].size.width += padding - trailingKern / 2
            rects += frames.map { frame in
                let minX = max(context.columnStart, frame.minX)
                return NSRect(x: minX, y: frame.minY, width: frame.maxX - minX, height: frame.height)
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

    // MARK: - Code boxes and quote bars

    /// One box per fenced block, from its opening fence through its closing
    /// one, or to the end of the text when it is unclosed. Its height comes
    /// from the fragment frames, which include the spacing the styler puts
    /// before the opening fence and after the closing one.
    private static func codeBoxRects(_ lines: [MarkdownLine], _ context: Context) -> [NSRect] {
        var boxes: [NSRect] = []
        var current: NSRect?
        var isOpen = false
        for line in lines {
            let isCode = line.kind == .fence || line.kind == .code
            guard isCode, let frame = context.fragmentRect(of: line) else {
                if let box = current { boxes.append(box) }
                current = nil
                isOpen = false
                continue
            }
            current = current.map { $0.union(frame) } ?? frame
            if line.kind == .fence {
                if isOpen, let box = current {
                    boxes.append(box)
                    current = nil
                }
                isOpen.toggle()
            }
        }
        if let box = current { boxes.append(box) }
        return boxes.map { box in
            NSRect(x: context.columnStart, y: box.minY, width: context.columnEnd - context.columnStart, height: box.height)
        }
    }

    /// One bar per quote level per run of consecutive lines quoted at least
    /// that deep.
    private static func quoteBarRects(_ lines: [MarkdownLine], _ context: Context) -> [NSRect] {
        var bars: [NSRect] = []
        var open: [Int: NSRect] = [:]
        func close(from level: Int) {
            for key in open.keys.sorted() where key >= level {
                if let bar = open.removeValue(forKey: key) { bars.append(bar) }
            }
        }
        for line in lines {
            close(from: line.quoteLevel)
            guard line.quoteLevel > 0, let frame = context.fragmentRect(of: line) else { continue }
            for level in 0..<line.quoteLevel {
                let x = context.columnStart + context.metrics.quoteBarX(level: level)
                let rect = NSRect(x: x, y: frame.minY, width: context.metrics.quoteBarWidth, height: frame.height)
                open[level] = open[level].map { $0.union(rect) } ?? rect
            }
        }
        close(from: 0)
        return bars.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }
}
