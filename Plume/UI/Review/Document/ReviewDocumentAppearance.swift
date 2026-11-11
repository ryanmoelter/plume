#if DEBUG
import AppKit
import SwiftUI

/// The colors and font the document draws with, resolved from the theme
/// once per change rather than per row.
struct ReviewDocumentAppearance: Equatable {
    var font: NSFont
    var background: NSColor
    var foreground: NSColor
    var subtle: NSColor
    var attention: NSColor
    var warning: NSColor
    var success: NSColor
    var danger: NSColor
    var addedTint: NSColor
    var removedTint: NSColor
    var hunkTint: NSColor
    var selectingTint: NSColor
    var draftedTint: NSColor
    var headerTint: NSColor
    var divider: NSColor
    var keyword: NSColor
    var string: NSColor
    var comment: NSColor
    var number: NSColor
    var type: NSColor

    @MainActor
    init(palette colors: Palette, font: NSFont) {
        self.font = font
        background = colors.background.map { NSColor($0) } ?? .textBackgroundColor
        foreground = NSColor(colors.foreground)
        subtle = NSColor(colors.foreground.emphasized(.subtle, in: colors))
        attention = NSColor(colors.attention)
        warning = NSColor(colors.warning)
        success = NSColor(colors.success)
        danger = NSColor(colors.danger)
        addedTint = NSColor(colors.success.emphasized(.backgroundTint, in: colors))
        removedTint = NSColor(colors.danger.emphasized(.backgroundTint, in: colors))
        hunkTint = NSColor(colors.attention.opacity(0.08))
        selectingTint = NSColor(colors.selection.opacity(0.28))
        draftedTint = NSColor(colors.selection.opacity(0.12))
        headerTint = NSColor(colors.surfaceTint)
        divider = NSColor(colors.divider)
        let syntax = CodeSyntaxPalette(palette: colors)
        keyword = NSColor(syntax.keyword)
        string = NSColor(syntax.string)
        comment = NSColor(syntax.comment)
        number = NSColor(syntax.number)
        type = NSColor(syntax.type)
    }

    func color(for token: CodeSyntax.Token) -> NSColor {
        switch token {
        case .plain: foreground
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type: type
        }
    }

    func color(for kind: DiffChangeKind) -> NSColor {
        switch kind {
        case .added: success
        case .modified: warning
        case .deleted: danger
        case .renamed: attention
        }
    }

    func tint(for highlight: ReviewLineHighlight) -> NSColor {
        switch highlight {
        case .selecting: selectingTint
        case .drafted: draftedTint
        }
    }

    func tint(for kind: FileDiff.LineKind) -> NSColor? {
        switch kind {
        case .context: nil
        case .added: addedTint
        case .removed: removedTint
        }
    }
}

/// Sizes that follow from the font, plus the fixed gutter.
struct ReviewDocumentMetrics: Equatable {
    static let numberWidth: CGFloat = 44
    static let markerWidth: CGFloat = 16
    static let gutterWidth = (numberWidth + 4) * 2 + markerWidth
    static let textInset: CGFloat = 8
    static let headerHeight: CGFloat = 34
    static let messageHeight: CGFloat = 44
    static let defaultCommentHeight: CGFloat = 90

    let lineHeight: CGFloat
    let characterWidth: CGFloat
    let ascent: CGFloat

    init(font: NSFont) {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        self.ascent = ascent
        lineHeight = ceil(ascent + descent + leading) + 2
        characterWidth = max(("0" as NSString).size(withAttributes: [.font: font]).width, 1)
    }

    /// The baseline of a single line drawn at the top of a row.
    var baseline: CGFloat { 1 + ascent }

    func codeWidth(columns: Int) -> CGFloat {
        Self.gutterWidth + Self.textInset + CGFloat(columns) * characterWidth + 24
    }
}

/// Builds the attributed text a row draws, with the syntax colors applied.
@MainActor
enum ReviewDocumentText {
    static func attributed(
        _ text: String,
        spans: [CodeSyntax.Span],
        appearance: ReviewDocumentAppearance,
        metrics: ReviewDocumentMetrics,
        color: NSColor? = nil
    ) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: appearance.font,
            .foregroundColor: color ?? appearance.foreground,
            .paragraphStyle: paragraphStyle(metrics),
        ])
        let length = string.length
        for span in spans where span.range.upperBound <= length {
            string.addAttribute(
                .foregroundColor,
                value: appearance.color(for: span.token),
                range: NSRange(location: span.range.lowerBound, length: span.range.count)
            )
        }
        return string
    }

    static func paragraphStyle(_ metrics: ReviewDocumentMetrics) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = metrics.characterWidth * CGFloat(ReviewDocument.tabWidth)
        style.tabStops = []
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Draws one line with its baseline at `baseline`, in a flipped view.
    static func draw(_ line: CTLine, at point: CGPoint, baseline: CGFloat, in context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Draws wrapped text into `rect`, in a flipped view.
    static func draw(_ frameSetter: CTFramesetter, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height), transform: nil)
        let frame = CTFramesetterCreateFrame(frameSetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

/// Wrapped heights, measured off the main actor.
nonisolated enum ReviewWrapMeasure {
    static func heights(
        of texts: [String],
        fontName: String,
        fontSize: CGFloat,
        tabInterval: CGFloat,
        width: CGFloat,
        lineHeight: CGFloat
    ) -> [String: CGFloat] {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = tabInterval
        style.tabStops = []
        style.lineBreakMode = .byWordWrapping
        var heights: [String: CGFloat] = [:]
        for text in texts where heights[text] == nil {
            let string = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
            let setter = CTFramesetterCreateWithAttributedString(string)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                setter, CFRange(location: 0, length: 0), nil,
                CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil
            )
            heights[text] = max(lineHeight, ceil(size.height) + 2)
        }
        return heights
    }
}
#endif
