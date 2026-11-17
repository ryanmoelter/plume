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

    struct ReferenceChip: Equatable {
        /// One per line the token occupies.
        var rects: [NSRect]
        var iconRect: NSRect
        var glyph: StatusGlyph
        var tint: NSColor
        var wash: NSColor
        var brandRect: NSRect?
        var brand: ReferenceChipBrand?
        var textTint: NSColor = .linkColor
        var title: Title?
        var toolTip: ComposerReferenceChip.ToolTip?
    }

    /// A chip's title, drawn from the left end of its baseline.
    struct Title: Equatable {
        var text: String
        var baselineOrigin: NSPoint
        var font: NSFont
    }

    struct Decorations: Equatable {
        var chips: [NSRect] = []
        var referenceChips: [ReferenceChip] = []
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
        for chip in decorations.referenceChips {
            drawReferenceChip(chip, in: dirtyRect, metrics: metrics)
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

    private static func drawReferenceChip(_ chip: ReferenceChip, in dirtyRect: NSRect, metrics: ComposerMarkdownMetrics) {
        for rect in chip.rects where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: metrics.chipCornerRadius, yRadius: metrics.chipCornerRadius)
            ComposerMarkdownMetrics.codeBackground.setFill()
            path.fill()
            chip.wash.setFill()
            path.fill()
        }
        if let brand = chip.brand, let brandRect = chip.brandRect, brandRect.intersects(dirtyRect),
           let logo = NSImage(named: brand.imageName) {
            let inset = brandRect.width * (1 - ReferenceChipMetrics.brandScale) / 2
            drawTemplate(logo, tint: chip.textTint, fittedIn: brandRect.insetBy(dx: inset, dy: inset))
        }
        if let title = chip.title, chip.rects.first?.intersects(dirtyRect) == true {
            (title.text as NSString).draw(
                with: NSRect(origin: title.baselineOrigin, size: .zero),
                options: [],
                attributes: [.font: title.font, .foregroundColor: chip.textTint]
            )
        }
        guard chip.iconRect.intersects(dirtyRect),
              let image = chip.glyph.image(side: chip.iconRect.height, color: chip.tint),
              image.size.width > 0, image.size.height > 0
        else { return }
        let scale = min(chip.iconRect.width / image.size.width, chip.iconRect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: chip.iconRect.midX - size.width / 2,
            y: chip.iconRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private static func drawTemplate(_ image: NSImage, tint: NSColor, fittedIn square: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(square.width / image.size.width, square.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let tinted = NSImage(size: size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(
            in: NSRect(x: square.midX - size.width / 2, y: square.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
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

    /// `references` defaults to the chips the text view holds. With
    /// `visibleRect`, only the decorations on the lines it shows are found,
    /// so the cost of a redraw follows the viewport rather than the text; a
    /// code box or quote bar that reaches past it still spans its whole run.
    /// `structure` must be built from the text view's current text.
    static func rects(
        in textView: NSTextView,
        metrics: ComposerMarkdownMetrics,
        references: [ComposerReferenceChip]? = nil,
        visibleRect: NSRect? = nil,
        structure: Structure? = nil
    ) -> Decorations {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let storage = textView.textStorage,
              storage.length > 0
        else { return Decorations() }

        let structure = structure ?? Structure(text: storage.string)
        let lines = structure.lines
        let context = Context(
            textView: textView,
            layoutManager: layoutManager,
            contentStorage: contentStorage,
            length: storage.length,
            metrics: metrics
        )
        let shown: ClosedRange<Int>
        if let visibleRect {
            let origin = textView.textContainerOrigin
            layoutManager.ensureLayout(for: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y))
            shown = context.lineIndices(showing: visibleRect, in: lines)
        } else {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            shown = 0...(lines.count - 1)
        }
        let shownCharacters = NSRange(
            location: lines[shown.lowerBound].range.location,
            length: NSMaxRange(lines[shown.upperBound].range) - lines[shown.lowerBound].range.location
        )
        func isShown(_ range: NSRange) -> Bool {
            range.location <= NSMaxRange(shownCharacters) && NSMaxRange(range) >= shownCharacters.location
        }

        var decorations = Decorations()
        decorations.chips = chipRects(structure.inlineCode.filter(isShown), context)
        let references = references ?? (textView as? ComposerNSTextView)?.referenceChips ?? []
        decorations.referenceChips = referenceChipRects(references.filter { isShown($0.range) }, context)
        decorations.codeBoxes = structure.codeRuns.filter { $0.overlaps(shown) }.compactMap { run in
            codeBoxRect(lines[run.lowerBound], lines[run.upperBound], context)
        }
        decorations.quoteBars = structure.quoteRuns.filter { $0.lines.overlaps(shown) }.compactMap { run in
            quoteBarRect(run, lines, context)
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        for line in lines[shown] {
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

        /// The fragment frames from `first` through `last`, which lay out
        /// top to bottom.
        func runRect(_ first: MarkdownLine, _ last: MarkdownLine) -> NSRect? {
            guard let top = fragmentRect(of: first), let bottom = fragmentRect(of: last) else { return nil }
            return top.union(bottom)
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

        /// The lines laid out in `rect`, in view coordinates, plus one on each
        /// side. A layout fragment is a paragraph, which holds more than one
        /// line when they end at U+2028 or U+0085, so every line of the
        /// paragraphs at either edge counts.
        func lineIndices(showing rect: NSRect, in lines: [MarkdownLine]) -> ClosedRange<Int> {
            func indices(atY y: CGFloat) -> ClosedRange<Int>? {
                guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y - origin.y)) else { return nil }
                let start = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
                let end = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.endLocation)
                let first = MarkdownLineStructure.lineIndex(containing: start, in: lines)
                return first...max(first, MarkdownLineStructure.lineIndex(containing: max(start, end - 1), in: lines))
            }
            let last = lines.count - 1
            let first = rect.minY <= origin.y ? 0 : indices(atY: rect.minY)?.lowerBound ?? last
            let end = indices(atY: rect.maxY)?.upperBound ?? last
            return max(0, first - 1)...min(last, max(first, end) + 1)
        }

        /// The y of the baseline of the line `location` lays out on, in view
        /// coordinates.
        func baseline(at location: Int) -> CGFloat? {
            guard let textLocation = contentStorage.location(contentStorage.documentRange.location, offsetBy: location),
                  let fragment = layoutManager.textLayoutFragment(for: textLocation)
            else { return nil }
            let offset = contentStorage.offset(from: fragment.rangeInElement.location, to: textLocation)
            guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(offset, $0.characterRange) })
                ?? fragment.textLineFragments.first
            else { return nil }
            return fragment.layoutFragmentFrame.minY + origin.y + line.typographicBounds.minY + line.glyphOrigin.y
        }

        func font(at location: Int) -> NSFont? {
            guard location >= 0, location < length else { return nil }
            return textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
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
    private static func chipRects(_ spans: [NSRange], _ context: Context) -> [NSRect] {
        let padding = context.metrics.chipPadding
        var rects: [NSRect] = []
        for span in spans {
            var frames = context.segmentFrames(for: span)
            guard !frames.isEmpty else { continue }
            let leadingKern = context.kern(at: span.location - 1)
            let trailingKern = context.kern(at: NSMaxRange(span) - 1)
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

    /// A code chip's rects around the token, the icon squares at its hidden
    /// trigger's glyph, and any title after them.
    private static func referenceChipRects(_ chips: [ComposerReferenceChip], _ context: Context) -> [ReferenceChip] {
        let padding = context.metrics.chipPadding
        let chipMetrics = ReferenceChipMetrics(fontSize: context.metrics.fontSize)
        return chips.compactMap { chip in
            guard chip.range.length > 1, NSMaxRange(chip.range) <= context.length else { return nil }
            var frames = context.segmentFrames(for: chip.range)
            guard !frames.isEmpty else { return nil }
            let leadingKern = context.kern(at: chip.range.location - 1)
            let trailingKern = context.kern(at: NSMaxRange(chip.range) - 1)
            let iconX = frames[0].minX + leadingKern / 2
            let firstMinX = iconX - padding
            frames[0] = NSRect(x: firstMinX, y: frames[0].minY, width: frames[0].maxX - firstMinX, height: frames[0].height)
            frames[frames.count - 1].size.width += padding - trailingKern / 2
            let rects = merged(frames.map { frame in
                let minX = max(context.columnStart, frame.minX)
                return NSRect(x: minX, y: frame.minY, width: frame.maxX - minX, height: frame.height)
            })
            guard let firstLine = rects.first else { return nil }
            let leadingX = max(context.columnStart, iconX)
            let icons = chipMetrics.iconRects(leadingX: leadingX, chipMidY: firstLine.midY, brand: chip.brand)
            let title = chip.title.flatMap { text in
                context.baseline(at: chip.range.location).map { baseline in
                    Title(
                        text: text,
                        baselineOrigin: NSPoint(x: leadingX + chipMetrics.triggerKern(brand: chip.brand), y: baseline),
                        font: context.font(at: NSMaxRange(chip.range) - 1) ?? context.metrics.body
                    )
                }
            }
            return ReferenceChip(
                rects: rects,
                iconRect: icons.status,
                glyph: chip.glyph,
                tint: chip.tint,
                wash: chip.wash,
                brandRect: icons.brand,
                brand: chip.brand,
                textTint: chip.textTint,
                title: title,
                toolTip: chip.toolTip
            )
        }
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

    /// What the decorations read from the text alone, kept by a view for as
    /// long as its text is unchanged, so a redraw after a scroll only asks the
    /// layout where things are.
    struct Structure {
        let lines: [MarkdownLine]
        let inlineCode: [NSRange]
        /// Each fenced block's lines, from its opening fence through its
        /// closing one, or to the end of the text when it is unclosed.
        let codeRuns: [ClosedRange<Int>]
        /// Each run of consecutive lines quoted at least `level + 1` deep.
        let quoteRuns: [(level: Int, lines: ClosedRange<Int>)]

        init(text: String) {
            lines = MarkdownLineStructure.lines(in: text)
            inlineCode = MarkdownHighlighter.spans(in: text).filter { $0.style == .inlineCode }.map(\.range)

            var codeRuns: [ClosedRange<Int>] = []
            var start: Int?
            var isOpen = false
            var quoteRuns: [(level: Int, lines: ClosedRange<Int>)] = []
            var quoteStarts: [Int] = []
            for (index, line) in lines.enumerated() {
                while quoteStarts.count > line.quoteLevel, let open = quoteStarts.popLast() {
                    quoteRuns.append((quoteStarts.count, open...(index - 1)))
                }
                while quoteStarts.count < line.quoteLevel {
                    quoteStarts.append(index)
                }

                guard line.kind == .fence || line.kind == .code else {
                    if let start { codeRuns.append(start...(index - 1)) }
                    start = nil
                    isOpen = false
                    continue
                }
                if start == nil { start = index }
                if line.kind == .fence {
                    if isOpen, let open = start {
                        codeRuns.append(open...index)
                        start = nil
                    }
                    isOpen.toggle()
                }
            }
            if let start { codeRuns.append(start...(lines.count - 1)) }
            while let open = quoteStarts.popLast() {
                quoteRuns.append((quoteStarts.count, open...(lines.count - 1)))
            }
            self.codeRuns = codeRuns
            self.quoteRuns = quoteRuns
        }
    }

    /// The box behind a fenced code block. Its height comes from the fragment
    /// frames, which include the spacing the styler puts before the opening
    /// fence and after the closing one.
    private static func codeBoxRect(_ first: MarkdownLine, _ last: MarkdownLine, _ context: Context) -> NSRect? {
        guard let frame = context.runRect(first, last) else { return nil }
        let column = first.listContainer == nil ? 0 : context.metrics.contentColumn(for: first)
        let minX = context.columnStart + column
        return NSRect(x: minX, y: frame.minY, width: max(0, context.columnEnd - minX), height: frame.height)
    }

    private static func quoteBarRect(_ run: (level: Int, lines: ClosedRange<Int>), _ lines: [MarkdownLine], _ context: Context) -> NSRect? {
        guard let frame = context.runRect(lines[run.lines.lowerBound], lines[run.lines.upperBound]) else { return nil }
        let x = context.columnStart + context.metrics.quoteBarX(level: run.level)
        return NSRect(x: x, y: frame.minY, width: context.metrics.quoteBarWidth, height: frame.height)
    }
}
