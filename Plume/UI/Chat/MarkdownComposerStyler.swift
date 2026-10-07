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
    static func style(
        _ storage: NSTextStorage,
        text: String,
        fontSize: CGFloat,
        recognizedSlashCommandNames: Set<String> = [],
        isCommandMode: Bool = false,
        accent: NSColor = ThemeChrome.accentNSColor()
    ) {
        let metrics = ComposerMarkdownMetrics(fontSize: fontSize)
        let bodyFont = isCommandMode ? metrics.mono : metrics.body
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        storage.setAttributes([
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)

        // A command is shell, not markdown: highlighting its quotes and
        // backticks as markup would style the parts that matter most.
        guard !isCommandMode else {
            storage.endEditing()
            return
        }

        let lines = MarkdownLineStructure.lines(in: text)
        let spans = MarkdownHighlighter.spans(in: text, lines: lines)
        for span in spans where span.style != .delimiter && fullRange.contains(span.range) {
            apply(span, to: storage, metrics: metrics, accent: accent)
        }
        for span in spans where span.style == .delimiter && fullRange.contains(span.range) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
        }
        padChips(spans, in: storage, text: ns, metrics: metrics)
        var isInsideFence = false
        for line in lines {
            if line.kind == .fence { isInsideFence.toggle() }
            applyLine(line, opensFence: isInsideFence, to: storage, text: ns, metrics: metrics)
        }

        if let commandRange = SlashCommandMatcher.recognizedCommandRange(text: text, commandNames: recognizedSlashCommandNames) {
            storage.addAttribute(.foregroundColor, value: accent, range: commandRange)
        }

        storage.endEditing()
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

    /// Line-level presentation: hidden or dimmed markers, and the paragraph
    /// style that places the content at its column. A paragraph style covers
    /// the whole paragraph, so it is set on the line plus its terminator.
    private static func applyLine(
        _ line: MarkdownLine,
        opensFence: Bool,
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

    /// Where a line's content starts, measured from the text column's
    /// leading edge. Zero leaves the line's own layout alone.
    func contentColumn(for line: MarkdownLine) -> CGFloat {
        let quotes = CGFloat(line.quoteLevel) * quoteStep
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

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}
