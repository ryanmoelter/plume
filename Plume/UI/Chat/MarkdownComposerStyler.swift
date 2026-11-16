import AppKit
import SwiftUI

/// Applies `MarkdownHighlighter` spans and `MarkdownLineStructure` lines as
/// `NSAttributedString` attributes on the composer's text storage — the
/// AppKit half of WYSIWYM styling.
///
/// Every character stays in the text. Inline syntax and heading `#`s are
/// dimmed; quote markers, bullets, task boxes and rules are made clear, and
/// `ComposerDecorations` draws a bar, glyph, box or line in their place.
/// Font sizes mirror `MarkdownView`'s heading ladder so the composer and the
/// rendered message agree visually.
@MainActor
enum MarkdownComposerStyler {
    /// Restyles `storage`, which holds `text`. Given the `Snapshot` the last
    /// call returned and the lengths at either end of the text that stayed
    /// the same since then, only the lines whose styling can have changed
    /// are restyled: the edited ones, plus any whose parse, fence side or
    /// list spacing moved, and any whose reference chip, command or mention
    /// tint did. Without both, the whole text is restyled.
    @discardableResult
    static func style(
        _ storage: NSTextStorage,
        text: String,
        fontSize: CGFloat,
        recognizedSlashCommandNames: Set<String> = [],
        isCommandMode: Bool = false,
        accent: NSColor = ThemeChrome.accentNSColor(),
        references: [ComposerReferenceChip] = [],
        activeMention: NSRange? = nil,
        after previous: Snapshot? = nil,
        unchanged: UnchangedEnds? = nil
    ) -> Snapshot? {
        let metrics = ComposerMarkdownMetrics(fontSize: fontSize)
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // A command is shell, not markdown: highlighting its quotes and
        // backticks as markup would style the parts that matter most.
        guard !isCommandMode else {
            storage.setAttributes([
                .font: metrics.mono,
                .foregroundColor: NSColor.labelColor,
            ], range: fullRange)
            return nil
        }

        let lines = MarkdownLineStructure.lines(in: text)
        var opensFence: [Bool] = []
        opensFence.reserveCapacity(lines.count)
        var isInsideFence = false
        for line in lines {
            if line.kind == .fence { isInsideFence.toggle() }
            opensFence.append(isInsideFence)
        }
        let commandRange = SlashCommandMatcher.recognizedCommandRange(text: text, commandNames: recognizedSlashCommandNames)
        let mentionRange = activeMention.flatMap { $0.length > 0 && NSMaxRange($0) <= ns.length ? $0 : nil }
        var snapshot = Snapshot(
            length: ns.length,
            lines: lines,
            opensFence: opensFence,
            listEdges: lines.indices.map { listEdges(at: $0, in: lines) },
            references: references,
            tints: [commandRange, mentionRange].compactMap { $0 },
            configuration: Configuration(fontSize: fontSize, accent: accent)
        )

        let groups: [ClosedRange<Int>]
        if let previous, let unchanged, previous.configuration == snapshot.configuration,
           let changed = snapshot.linesChanged(since: previous, unchanged: unchanged) {
            groups = wholeParagraphs(changed, of: lines, in: ns)
        } else {
            groups = [0...(lines.count - 1)]
        }

        let spans = MarkdownHighlighter.spans(in: text)
        storage.beginEditing()
        var restyled: NSRange?
        for group in groups {
            let first = lines[group.lowerBound].range.location
            let last = lines[group.upperBound]
            let end = last.range.location < ns.length
                ? NSMaxRange(ns.paragraphRange(for: NSRange(location: last.range.location, length: 0)))
                : ns.length
            let range = NSRange(location: first, length: end - first)
            restyled = restyled.map { NSUnionRange($0, range) } ?? range
            styleRange(
                range,
                lines: group,
                of: snapshot,
                spans: spans,
                in: storage,
                text: ns,
                metrics: metrics,
                accent: accent,
                commandRange: commandRange,
                mentionRange: mentionRange
            )
        }
        storage.endEditing()
        snapshot.restyled = restyled
        return snapshot
    }

    /// Widens each run of lines to whole paragraphs. A line ends at U+2028
    /// and U+0085 too, but a paragraph doesn't, and the paragraph style of a
    /// paragraph's last line is the one that sticks.
    private static func wholeParagraphs(_ groups: [ClosedRange<Int>], of lines: [MarkdownLine], in ns: NSString) -> [ClosedRange<Int>] {
        func continuesParagraph(_ index: Int) -> Bool {
            guard index > 0, index < lines.count else { return false }
            let previous = ns.character(at: lines[index].range.location - 1)
            return previous == 0x2028 || previous == 0x85
        }
        var result: [ClosedRange<Int>] = []
        for group in groups {
            var lower = group.lowerBound
            var upper = group.upperBound
            while continuesParagraph(lower) { lower -= 1 }
            while continuesParagraph(upper + 1) { upper += 1 }
            if let last = result.last, last.upperBound + 1 >= lower {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                result.append(lower...upper)
            }
        }
        return result
    }

    /// Styles `range`, the whole paragraphs of lines `indices` of
    /// `snapshot`: the base attributes, then spans, chip padding, references,
    /// each line's presentation and the accent tints, each cut to `range`.
    private static func styleRange(
        _ range: NSRange,
        lines indices: ClosedRange<Int>,
        of snapshot: Snapshot,
        spans: [MarkdownHighlighter.Span],
        in storage: NSTextStorage,
        text ns: NSString,
        metrics: ComposerMarkdownMetrics,
        accent: NSColor,
        commandRange: NSRange?,
        mentionRange: NSRange?
    ) {
        func clamped(_ other: NSRange) -> NSRange? {
            let intersection = NSIntersectionRange(other, range)
            return intersection.length > 0 ? intersection : nil
        }
        storage.setAttributes([
            .font: metrics.body,
            .foregroundColor: NSColor.labelColor,
        ], range: range)

        for span in spans where span.style != .delimiter {
            if let part = clamped(span.range) {
                apply(MarkdownHighlighter.Span(range: part, style: span.style), to: storage, metrics: metrics, accent: accent)
            }
        }
        for span in spans where span.style == .delimiter {
            if let part = clamped(span.range) {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: part)
            }
        }
        padChips(spans.filter { clamped($0.range) != nil }, in: storage, text: ns, metrics: metrics)
        styleReferences(snapshot.references.filter { clamped($0.range) != nil }, in: storage, text: ns, metrics: metrics, accent: accent)
        for index in indices {
            applyLine(
                snapshot.lines[index],
                opensFence: snapshot.opensFence[index],
                listEdges: snapshot.listEdges[index],
                to: storage,
                text: ns,
                metrics: metrics
            )
        }

        if let commandRange, let part = clamped(commandRange) {
            storage.addAttribute(.foregroundColor, value: accent, range: part)
        }
        if let mentionRange, let part = clamped(mentionRange) {
            storage.addAttribute(.foregroundColor, value: accent, range: part)
        }
    }

    /// The lengths of the text's start and end that no edit touched.
    struct UnchangedEnds: Equatable {
        var prefix: Int
        var suffix: Int

        static let all = UnchangedEnds(prefix: .max, suffix: .max)

        /// Narrows to exclude an edit, given as the edited range and the
        /// text's length afterwards.
        mutating func exclude(_ edited: NSRange, length: Int) {
            prefix = min(prefix, edited.location)
            suffix = min(suffix, length - NSMaxRange(edited))
        }
    }

    /// The inputs a restyle styled each line from, for the next restyle to
    /// compare against.
    struct Snapshot {
        fileprivate let length: Int
        fileprivate let lines: [MarkdownLine]
        fileprivate let opensFence: [Bool]
        fileprivate let listEdges: [ListEdges]
        fileprivate let references: [ComposerReferenceChip]
        /// The recognized command and the active mention.
        fileprivate let tints: [NSRange]
        fileprivate let configuration: Configuration
        /// The characters this restyle set attributes on, nil when no line
        /// needed it.
        fileprivate(set) var restyled: NSRange?

        /// Runs of consecutive lines to restyle, or nil when the edit can't
        /// be placed and everything needs it.
        fileprivate func linesChanged(since old: Snapshot, unchanged: UnchangedEnds) -> [ClosedRange<Int>]? {
            let prefix = min(unchanged.prefix, old.length, length)
            let suffix = min(unchanged.suffix, old.length - prefix, length - prefix)
            let delta = length - old.length
            let oldEditEnd = old.length - suffix
            let newEditEnd = length - suffix

            // Lines whose paragraph, terminator included, ends before the
            // edit, and lines starting after the character the edit ends at.
            func leading(_ lines: [MarkdownLine]) -> Int {
                var count = 0
                while count + 1 < lines.count, lines[count + 1].range.location <= prefix { count += 1 }
                return count
            }
            func trailing(_ lines: [MarkdownLine], after editEnd: Int) -> Int {
                var count = 0
                while count < lines.count, lines[lines.count - 1 - count].range.location > editEnd { count += 1 }
                return count
            }
            let before = leading(lines)
            let after = trailing(lines, after: newEditEnd)
            guard before == leading(old.lines), after == trailing(old.lines, after: oldEditEnd),
                  before + after <= lines.count, before + after <= old.lines.count
            else { return nil }

            var changed = IndexSet(integersIn: before..<(lines.count - after))
            for index in 0..<before where !sameStyling(index, old, index, shift: 0) {
                changed.insert(index)
            }
            for offset in 0..<after {
                let index = lines.count - after + offset
                if !sameStyling(index, old, old.lines.count - after + offset, shift: delta) {
                    changed.insert(index)
                }
            }

            func moved(_ range: NSRange) -> NSRange? {
                if NSMaxRange(range) <= prefix { return range }
                if range.location >= oldEditEnd { return NSRange(location: range.location + delta, length: range.length) }
                return nil
            }
            func insertLines(of range: NSRange) {
                let clamped = NSRange(location: min(range.location, length), length: 0)
                let first = MarkdownLineStructure.lineIndex(containing: clamped.location, in: lines)
                let last = MarkdownLineStructure.lineIndex(containing: min(NSMaxRange(range), length), in: lines)
                changed.insert(integersIn: first...max(first, last))
            }
            let newReferences = references.map { ReferenceStyle($0) }
            let oldReferences = old.references.compactMap { reference in
                moved(reference.range).map { ReferenceStyle(reference, range: $0) }
            }
            for reference in newReferences where !oldReferences.contains(reference) { insertLines(of: reference.range) }
            for reference in oldReferences where !newReferences.contains(reference) { insertLines(of: reference.range) }
            let oldTints = old.tints.compactMap(moved)
            if oldTints != tints {
                for range in oldTints + tints { insertLines(of: range) }
            }

            return changed.rangeView.map { $0.lowerBound...($0.upperBound - 1) }
        }

        /// What of a chip reaches its characters' attributes. Its colors are
        /// only drawn, and a dynamic color never equals the last one.
        private struct ReferenceStyle: Equatable {
            var range: NSRange
            var brand: ReferenceChipBrand?
            var title: String?

            init(_ chip: ComposerReferenceChip, range: NSRange? = nil) {
                self.range = range ?? chip.range
                brand = chip.brand
                title = chip.title
            }
        }

        private func sameStyling(_ index: Int, _ old: Snapshot, _ oldIndex: Int, shift: Int) -> Bool {
            opensFence[index] == old.opensFence[oldIndex]
                && listEdges[index] == old.listEdges[oldIndex]
                && lines[index] == old.lines[oldIndex].offset(by: shift)
        }
    }

    fileprivate struct Configuration: Equatable {
        var fontSize: CGFloat
        /// The accent as drawn in light and dark: a dynamic color is a new
        /// object on every call, and never equal to the last one.
        var accent: [NSColor?]

        init(fontSize: CGFloat, accent: NSColor) {
            self.fontSize = fontSize
            self.accent = [NSAppearance.Name.aqua, .darkAqua].map { name in
                var resolved: NSColor?
                NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                    resolved = accent.usingColorSpace(.sRGB)
                }
                return resolved
            }
        }
    }

    private static func apply(_ span: MarkdownHighlighter.Span, to storage: NSTextStorage, metrics: ComposerMarkdownMetrics, accent: NSColor) {
        let range = span.range
        switch span.style {
        case .bold:
            storage.addAttribute(.font, value: metrics.emphasis(bold: true, italic: false), range: range)
        case .italic:
            storage.addAttribute(.font, value: metrics.emphasis(bold: false, italic: true), range: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode, .codeBlock:
            storage.addAttribute(.font, value: metrics.mono, range: range)
        case let .heading(level):
            storage.addAttribute(.font, value: metrics.heading(level: level), range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: accent, range: range)
        case .listMarker, .blockQuote, .delimiter:
            break
        }
    }

    /// Opens a gap on each side of an inline code span for its chip: kern on
    /// the character before the opening backtick and on the closing one, the
    /// way the chat pads its own code. No padding character enters the text.
    private static func padChips(_ spans: [MarkdownHighlighter.Span], in storage: NSTextStorage, text ns: NSString, metrics: ComposerMarkdownMetrics) {
        for span in spans where span.style == .inlineCode {
            let before = span.range.location - 1
            if before >= 0, !isNewline(ns.character(at: before)) {
                storage.addAttribute(.kern, value: metrics.chipPadding, range: NSRange(location: before, length: 1))
            }
            storage.addAttribute(.kern, value: metrics.chipPadding, range: NSRange(location: NSMaxRange(span.range) - 1, length: 1))
        }
    }

    /// A reference chip's trigger is hidden, and kerned wide enough to hold
    /// the icons `ComposerDecorations` draws over it. The token is padded like
    /// a code chip, and a quoted path's quotes are dimmed rather than hidden.
    ///
    /// A titled chip hides the whole token and widens the trigger's kern to
    /// hold the title too. Its last character keeps its font, so a line
    /// holding nothing but the chip keeps its height.
    private static func styleReferences(_ references: [ComposerReferenceChip], in storage: NSTextStorage, text ns: NSString, metrics: ComposerMarkdownMetrics, accent: NSColor) {
        let chip = ReferenceChipMetrics(fontSize: metrics.fontSize)
        for reference in references where reference.range.length > 1 && NSMaxRange(reference.range) <= ns.length {
            let range = reference.range
            let last = NSMaxRange(range) - 1
            let trigger = NSRange(location: range.location, length: 1)
            storage.addAttribute(.foregroundColor, value: accent, range: range)
            var kern = chip.triggerKern(brand: reference.brand)
            if let title = reference.title {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                storage.addAttribute(.font, value: hiddenMarkerFont, range: NSRange(location: range.location, length: range.length - 1))
                let titleWidth = titleWidth(title, font: storage.attribute(.font, at: last, effectiveRange: nil) as? NSFont ?? metrics.body)
                kern = max(0, kern + titleWidth - typographicWidth(of: range, in: storage))
            }
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .font: hiddenMarkerFont,
                .kern: kern,
            ], range: trigger)
            if range.length > 3, ns.character(at: range.location + 1) == quote, ns.character(at: last) == quote {
                for location in [range.location + 1, last] {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: location, length: 1))
                }
            }
            let before = range.location - 1
            if before >= 0, !isNewline(ns.character(at: before)) {
                storage.addAttribute(.kern, value: metrics.chipPadding, range: NSRange(location: before, length: 1))
            }
            storage.addAttribute(.kern, value: metrics.chipPadding, range: NSRange(location: last, length: 1))
        }
    }

    private static let quote = "\"".utf16.first!

    /// Line-level presentation: hidden or dimmed markers, and the paragraph
    /// style that places the content at its column. A paragraph style covers
    /// the whole paragraph, so it is set on the line plus its terminator.
    private static func applyLine(
        _ line: MarkdownLine,
        opensFence: Bool,
        listEdges: ListEdges,
        to storage: NSTextStorage,
        text ns: NSString,
        metrics: ComposerMarkdownMetrics
    ) {
        let paragraphRange = line.range.location < ns.length
            ? ns.paragraphRange(for: NSRange(location: line.range.location, length: 0))
            : line.range
        for marker in line.quoteMarkers {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: marker)
        }

        let style = NSMutableParagraphStyle()
        switch line.kind {
        case .heading:
            if let marker = line.marker {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
            }
            style.paragraphSpacingBefore = metrics.fontSize * 0.4
            // The empty line Return leaves after a heading takes its look from
            // this terminator, so it carries the body font.
            if NSMaxRange(paragraphRange) > NSMaxRange(line.range) {
                let terminator = NSRange(location: NSMaxRange(line.range), length: NSMaxRange(paragraphRange) - NSMaxRange(line.range))
                storage.addAttribute(.font, value: metrics.body, range: terminator)
            }

        case .bullet, .task, .rule:
            if let marker = line.marker {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: marker)
            }
            if line.kind == .rule {
                style.paragraphSpacingBefore = metrics.fontSize * 0.3
                style.paragraphSpacing = metrics.fontSize * 0.3
            }

        case .ordered:
            if let marker = line.marker {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
                storage.addAttribute(.font, value: metrics.numberFont, range: marker)
            }

        case .fence, .code:
            if line.kind == .fence {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.range)
            }
            style.firstLineHeadIndent = metrics.codeInset
            style.headIndent = metrics.codeInset
            if let container = line.listContainer {
                for range in line.quoteMarkers + [container.indent] where range.length > 0 {
                    collapse(range, in: storage)
                }
                let column = metrics.contentColumn(for: line) + metrics.codeInset
                let prefix = NSRange(location: line.range.location, length: NSMaxRange(container.indent) - line.range.location)
                let prefixWidth = prefix.length > 0 ? typographicWidth(of: prefix, in: storage) : 0
                style.firstLineHeadIndent = max(0, column - prefixWidth)
                style.headIndent = column
            }
            if line.kind == .fence {
                if opensFence {
                    style.paragraphSpacingBefore = metrics.codeBoxSpacing
                } else {
                    style.paragraphSpacing = metrics.codeBoxSpacing
                }
            }

        case .plain, .blank:
            break
        }
        if listEdges.contains(.first) { style.paragraphSpacingBefore = metrics.listSpacing }
        if listEdges.contains(.last) { style.paragraphSpacing = metrics.listSpacing }

        if line.kind != .fence, line.kind != .code {
            let column = metrics.contentColumn(for: line)
            if column > 0 {
                var hidden = line.quoteMarkers
                if line.isListItem, line.hidesMarker {
                    hidden.append(NSRange(location: line.indent.location, length: line.contentStart - line.indent.location))
                }
                for range in hidden where range.length > 0 {
                    collapse(range, in: storage)
                }
                let prefix = NSRange(location: line.range.location, length: line.contentStart - line.range.location)
                let prefixWidth = prefix.length > 0 ? typographicWidth(of: prefix, in: storage) : 0
                style.firstLineHeadIndent = max(0, column - prefixWidth)
                style.headIndent = column
            }
        }
        storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
    }

    struct ListEdges: OptionSet {
        let rawValue: Int
        static let first = ListEdges(rawValue: 1 << 0)
        static let last = ListEdges(rawValue: 1 << 1)
    }

    /// Whether the line at `index` opens or closes a list that text sits
    /// directly against. A blank line already separates a list from its
    /// neighbors, so only a list touching text gets spacing.
    private static func listEdges(at index: Int, in lines: [MarkdownLine]) -> ListEdges {
        func isInList(_ line: MarkdownLine) -> Bool {
            line.isListItem || (line.kind == .plain && line.indent.length > 0) || line.listContainer != nil
        }
        func isText(_ line: MarkdownLine) -> Bool {
            line.kind != .blank && !isInList(line)
        }
        guard isInList(lines[index]) else { return [] }
        var edges: ListEdges = []
        if index > 0, isText(lines[index - 1]) { edges.insert(.first) }
        if index + 1 < lines.count, isText(lines[index + 1]) { edges.insert(.last) }
        return edges
    }

    /// Shrinks a hidden run so a marker wider than its column (`- [ ] `)
    /// still fits under the paragraph indent. TextKit 2 floors a negative
    /// kern at a fraction of the glyph, so a smaller font is what frees the
    /// width. The last character keeps the body font so an empty item's line
    /// keeps its height.
    private static func collapse(_ range: NSRange, in storage: NSTextStorage) {
        guard range.length > 1 else { return }
        storage.addAttribute(.font, value: hiddenMarkerFont, range: NSRange(location: range.location, length: range.length - 1))
    }

    private static let hiddenMarkerFont = NSFont.systemFont(ofSize: 1)

    static func titleWidth(_ title: String, font: NSFont) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The advance of `range` as CoreText sets it, trailing spaces included.
    private static func typographicWidth(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        let line = CTLineCreateWithAttributedString(storage.attributedSubstring(from: range))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}

/// Every font and length the composer's markdown presentation uses, built
/// from the body size, so the styler and `ComposerDecorations` agree on where
/// a column, bullet or bar sits.
@MainActor
struct ComposerMarkdownMetrics {
    let fontSize: CGFloat
    let body: NSFont
    let mono: NSFont
    /// Ordered-list numbers, with tabular digits so `9.` and `10.` align.
    let numberFont: NSFont

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        body = .composerBody(ofSize: fontSize)
        mono = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        numberFont = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
    }

    var quoteStep: CGFloat { fontSize * 1.0 }
    var listStep: CGFloat { fontSize * 1.4 }
    /// The space between a drawn bullet or checkbox and the item's text.
    var markerGap: CGFloat { fontSize * 0.4 }
    var chipPadding: CGFloat { fontSize * 0.25 }
    var chipCornerRadius: CGFloat { 4 }
    var codeInset: CGFloat { fontSize * 0.6 }
    var codeBoxSpacing: CGFloat { fontSize * 0.3 }
    var codeBoxCornerRadius: CGFloat { 6 }
    var quoteBarWidth: CGFloat { 3 }
    var ruleThickness: CGFloat { 1 }
    var checkboxSize: CGFloat { (fontSize * 0.85).rounded() }
    var listSpacing: CGFloat { fontSize * 0.7 }

    /// Where a line's content starts, measured from the text column's
    /// leading edge. Zero leaves the line's own layout alone.
    func contentColumn(for line: MarkdownLine) -> CGFloat {
        let quotes = CGFloat(line.quoteLevel) * quoteStep
        if let container = line.listContainer { return quotes + CGFloat(container.depth + 1) * listStep }
        return line.isListItem ? quotes + CGFloat(line.depth + 1) * listStep : quotes
    }

    /// The x of quote bar `level` (0 is outermost), from the text column's
    /// leading edge.
    func quoteBarX(level: Int) -> CGFloat {
        CGFloat(level) * quoteStep
    }

    func emphasis(bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = body.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: fontSize) ?? body
    }

    /// Mirrors `MarkdownView.headingFont(level:)`'s multiplier ladder.
    func heading(level: Int) -> NSFont {
        let (multiplier, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (2.15, .bold)
        case 2: (1.7, .bold)
        case 3: (1.35, .bold)
        case 4: (1.15, .semibold)
        case 5: (1.0, .semibold)
        default: (0.85, .semibold)
        }
        let size = fontSize * multiplier
        let base = NSFont.composerBody(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Matches `MarkdownView.codeBackground`: `ThemeChrome` foreground at 8%
    /// opacity, falling back to system secondary when no theme is set.
    /// Resolves per draw, so it tracks a light/dark switch.
    static let codeBackground = NSColor(name: nil) { appearance in
        themed(appearance, alpha: 0.08, fallbackAlpha: 0.1)
    }

    static let quoteBar = NSColor(name: nil) { appearance in
        themed(appearance, alpha: 0.25, fallbackAlpha: 0.3)
    }

    static let rule = NSColor(name: nil) { appearance in
        themed(appearance, alpha: 0.15, fallbackAlpha: 0.2)
    }

    private static func themed(_ appearance: NSAppearance, alpha: CGFloat, fallbackAlpha: CGFloat) -> NSColor {
        let scheme: ColorScheme =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        guard let themeColor = ThemeChrome.foreground(for: scheme) else {
            return NSColor.secondaryLabelColor.withAlphaComponent(fallbackAlpha)
        }
        return NSColor(themeColor).withAlphaComponent(alpha)
    }
}

