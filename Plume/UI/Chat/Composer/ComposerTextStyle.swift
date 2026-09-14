import AppKit
import SwiftUI

/// Every font, color, and paragraph metric the composer's text storage draws
/// with, built once from a body size.
///
/// `attributes(for:inline:link:)` is the single source of truth other
/// workstreams call to turn a block kind and an inline style into the actual
/// `NSAttributedString` attribute dictionary for a run — nothing outside this
/// type should hand-assemble fonts or paragraph styles for composer text.
nonisolated struct ComposerTextStyle {
    let bodySize: CGFloat
    let body: NSFont
    let mono: NSFont
    let codeBackground: NSColor
    let quoteBar: NSColor
    let chipCornerRadius: CGFloat = 4
    let chipPadding: CGFloat
    let codeBoxCornerRadius: CGFloat = 6
    let quoteBarWidth: CGFloat = 3

    /// Indexed by heading level 1...6; index 0 is unused padding so
    /// `heading(level:)` can subscript directly.
    private let headingFonts: [NSFont]

    init(bodySize: CGFloat) {
        self.bodySize = bodySize
        body = .composerBody(ofSize: bodySize)
        mono = .monospacedSystemFont(ofSize: bodySize, weight: .regular)
        chipPadding = bodySize * 0.25
        codeBackground = ComposerTextStyle.makeCodeBackground()
        quoteBar = ComposerTextStyle.makeQuoteBar()
        headingFonts = [NSFont.composerBody(ofSize: bodySize)]
            + (1...6).map { ComposerTextStyle.headingFont(level: $0, bodySize: bodySize) }
    }

    /// The heading font for `level`, mirroring the chat's own heading ladder.
    /// Out-of-range levels clamp rather than trap, since a level
    /// only ever comes from `MarkdownBlock`'s own 1...6 parse.
    func heading(level: Int) -> NSFont {
        headingFonts[max(1, min(level, 6))]
    }

    /// The font for a run of `kind`, with `inline` resolved on top: code
    /// wins outright (a bold or italic code span still renders in mono),
    /// otherwise bold/italic add symbolic traits to the kind's own base
    /// font — which for a heading already carries its ladder weight.
    func font(for kind: ComposerBlockKind.Kind, inline: ComposerInlineStyle = []) -> NSFont {
        if inline.contains(.code) { return mono }
        switch kind {
        case let .heading(level):
            return applying(inline, to: heading(level: level))
        case .codeBlock, .verbatim:
            return mono
        default:
            return applying(inline, to: body)
        }
    }

    private func applying(_ inline: ComposerInlineStyle, to base: NSFont) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if inline.contains(.bold) { traits.insert(.bold) }
        if inline.contains(.italic) { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Block-level layout metrics. `lists` is threaded through rather than
    /// built here so a caller can share one `NSTextList` per depth across
    /// every paragraph of a list — head indents for list paragraphs are the
    /// caller's responsibility for the same reason; `listIndent(depth:)` is
    /// the fallback for a caller with no `NSTextList` to hand.
    func paragraphStyle(
        for kind: ComposerBlockKind.Kind,
        isFirstInBlock: Bool = true,
        isLastInBlock: Bool = true,
        lists: [NSTextList] = []
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch kind {
        case .codeBlock, .verbatim:
            let padding = bodySize * 0.6
            style.firstLineHeadIndent = padding
            style.headIndent = padding
            if isFirstInBlock { style.paragraphSpacingBefore = bodySize * 0.3 }
            if isLastInBlock { style.paragraphSpacing = bodySize * 0.3 }

        case .heading:
            style.paragraphSpacingBefore = bodySize * 0.4

        case .quote:
            let indent = bodySize * 1.0
            style.headIndent = indent
            style.firstLineHeadIndent = indent

        case .bullet, .numbered:
            style.textLists = lists

        case .paragraph:
            break
        }
        return style
    }

    /// A list paragraph's head indent when no `NSTextList` carries it —
    /// `paragraphStyle(for:...)` deliberately leaves list indentation to the
    /// caller, so this is what a caller reaches for instead.
    func listIndent(depth: Int) -> CGFloat {
        bodySize * 1.4 * CGFloat(depth + 1)
    }

    /// The full attribute dictionary for a run: font, color, paragraph
    /// style, and the three `plume*` keys that carry the composer's own
    /// model. Every caller building composer text funnels through this so
    /// the vocabulary stays in one place.
    func attributes(
        for kind: ComposerBlockKind,
        inline: ComposerInlineStyle = [],
        link: URL? = nil,
        isFirstInBlock: Bool = true,
        isLastInBlock: Bool = true,
        lists: [NSTextList] = []
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font(for: kind.kind, inline: inline),
            .foregroundColor: link != nil ? NSColor.linkColor : NSColor.labelColor,
            .plumeBlock: kind,
            .plumeInline: inline,
            .paragraphStyle: paragraphStyle(
                for: kind.kind,
                isFirstInBlock: isFirstInBlock,
                isLastInBlock: isLastInBlock,
                lists: lists
            ),
        ]
        if let link {
            result[.plumeLink] = link
        }
        return result
    }

    private static func headingFont(level: Int, bodySize: CGFloat) -> NSFont {
        let (multiplier, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (2.15, .bold)
        case 2: (1.7, .bold)
        case 3: (1.35, .bold)
        case 4: (1.15, .semibold)
        case 5: (1.0, .semibold)
        default: (0.85, .semibold)
        }
        let size = bodySize * multiplier
        let base = NSFont.composerBody(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The chat's quote bar color: `Palette.surface(.disabled)`, which is the
    /// theme foreground at `Emphasis.disabled`'s alpha. Resolves per draw like
    /// `codeBackground` so it tracks a light/dark switch.
    private static func makeQuoteBar() -> NSColor {
        NSColor(name: nil) { appearance in
            let scheme: ColorScheme =
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            let alpha = Emphasis.disabled.fillOpacity(for: scheme)
            guard let themeColor = ThemeChrome.foreground(for: scheme) else {
                return NSColor.secondaryLabelColor.withAlphaComponent(alpha)
            }
            return NSColor(themeColor).withAlphaComponent(alpha)
        }
    }

    /// `ThemeChrome`'s foreground at 8% opacity, falling back to system
    /// secondary when no
    /// theme is set. Resolves per draw so it tracks a light/dark switch.
    private static func makeCodeBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            let scheme: ColorScheme =
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            guard let themeColor = ThemeChrome.foreground(for: scheme) else {
                return NSColor.secondaryLabelColor.withAlphaComponent(0.1)
            }
            return NSColor(themeColor).withAlphaComponent(0.08)
        }
    }
}
