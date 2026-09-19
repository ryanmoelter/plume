import AppKit
import SwiftUI

/// Applies `MarkdownHighlighter` spans as `NSAttributedString` attributes on
/// the composer's text storage — the AppKit half of WYSIWYM styling.
///
/// Marker characters (the `**`, `` ` ``, `#`, `-`, `>` themselves) are
/// styled dimmer than the content they wrap, so they read as scaffolding.
/// Font sizes mirror `MarkdownView`'s heading ladder so the composer and the
/// rendered message agree visually.
@MainActor
enum MarkdownComposerStyler {
    static func style(
        _ storage: NSTextStorage,
        text: String,
        fontSize: CGFloat,
        recognizedSlashCommandNames: Set<String> = []
    ) {
        let bodyFont = NSFont.composerBody(ofSize: fontSize)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        storage.setAttributes([
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)

        let spans = MarkdownHighlighter.spans(in: text)
        for span in spans {
            guard fullRange.contains(span.range) || span.range.length == 0 else { continue }
            apply(span, to: storage, bodyFontSize: fontSize)
        }
        for span in spans {
            guard fullRange.contains(span.range) || span.range.length == 0 else { continue }
            applyParagraphStyle(span, to: storage, text: text as NSString, bodyFontSize: fontSize)
        }

        if let commandRange = SlashCommandMatcher.recognizedCommandRange(text: text, commandNames: recognizedSlashCommandNames) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: commandRange)
        }

        applyCommandMode(to: storage, text: text, bodyFontSize: fontSize)

        storage.endEditing()
    }

    /// Command mode: a message starting with `!` runs rather than being said.
    ///
    /// Monospaced without the inline-code chip, so it reads as a different
    /// mode rather than as a code span — the background is the whole
    /// distinction between the two. The markdown pass runs first, so any chip
    /// it painted over a backtick inside the command is cleared here.
    ///
    /// The `!` itself is red rather than dimmed like other markers: it warns
    /// that sending runs something.
    private static func applyCommandMode(to storage: NSTextStorage, text: String, bodyFontSize: CGFloat) {
        guard let range = CommandModeMatcher.commandRange(text: text) else { return }
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular), range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        storage.removeAttribute(.backgroundColor, range: range)
        if let markerRange = CommandModeMatcher.markerRange(text: text) {
            storage.addAttribute(.foregroundColor, value: commandMarkerColor, range: markerRange)
        }
    }

    private static func apply(_ span: MarkdownHighlighter.Span, to storage: NSTextStorage, bodyFontSize: CGFloat) {
        let range = span.range
        switch span.style {
        case .bold:
            storage.addAttribute(.font, value: emphasisFont(bodyFontSize, bold: true, italic: false), range: range)
        case .italic:
            storage.addAttribute(.font, value: emphasisFont(bodyFontSize, bold: false, italic: true), range: range)
        case .inlineCode:
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            storage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: range)
        case .codeBlock:
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            storage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: range)
        case let .heading(level):
            storage.addAttribute(.font, value: headingFont(level: level, bodyFontSize: bodyFontSize), range: range)
        case .listMarker, .blockQuote:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        }

        if isMarkerOnly(span.style) {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    /// Block-level layout — hanging indents for lists and quotes, padding
    /// and spacing for code blocks, spacing above headings — via
    /// `NSParagraphStyle`. A paragraph style applies to the whole paragraph
    /// it's set on regardless of the range it's set with, so ranges here are
    /// always expanded to full paragraph boundaries first.
    private static func applyParagraphStyle(
        _ span: MarkdownHighlighter.Span,
        to storage: NSTextStorage,
        text ns: NSString,
        bodyFontSize: CGFloat
    ) {
        switch span.style {
        case .listMarker, .blockQuote:
            let indent = bodyFontSize * 1.4
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = 0
            style.headIndent = indent
            storage.addAttribute(.paragraphStyle, value: style, range: ns.paragraphRange(for: span.range))

        case .codeBlock:
            let padding = bodyFontSize * 0.6
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = padding
            style.headIndent = padding
            style.paragraphSpacingBefore = bodyFontSize * 0.3
            style.paragraphSpacing = bodyFontSize * 0.3
            storage.addAttribute(.paragraphStyle, value: style, range: span.range)

        case .heading:
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = bodyFontSize * 0.4
            storage.addAttribute(.paragraphStyle, value: style, range: ns.paragraphRange(for: span.range))

        default:
            break
        }
    }

    /// Bold/italic markers dim like other scaffolding; the emphasized
    /// content itself keeps the body color and only changes weight/slant —
    /// `apply` doesn't distinguish marker vs. content sub-ranges for
    /// bold/italic (unlike list/quote, which are marker-only spans), so this
    /// governs dimming for those two styles specifically via marker length.
    private static func isMarkerOnly(_ style: MarkdownHighlighter.Style) -> Bool {
        switch style {
        case .listMarker, .blockQuote:
            return true
        default:
            return false
        }
    }

    private static func emphasisFont(_ size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFont.composerBody(ofSize: size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Mirrors `MarkdownView.headingFont(level:)`'s multiplier ladder.
    private static func headingFont(level: Int, bodyFontSize: CGFloat) -> NSFont {
        let (multiplier, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (2.15, .bold)
        case 2: (1.7, .bold)
        case 3: (1.35, .bold)
        case 4: (1.15, .semibold)
        case 5: (1.0, .semibold)
        default: (0.85, .semibold)
        }
        let size = bodyFontSize * multiplier
        let base = NSFont.composerBody(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Matches `MarkdownView.codeBackground`: `ThemeChrome` foreground at 8%
    /// opacity, falling back to system secondary when no theme is set.
    ///
    /// Resolves per draw, so the text keeps its contrast across a light/dark
    /// switch without being restyled — nothing restyles it until the next
    /// keystroke.
    private static let codeBackgroundColor = NSColor(name: nil) { appearance in
        let scheme: ColorScheme =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        guard let themeColor = ThemeChrome.foreground(for: scheme) else {
            return NSColor.secondaryLabelColor.withAlphaComponent(0.1)
        }
        return NSColor(themeColor).withAlphaComponent(0.08)
    }

    /// The theme's destructive color, resolved per draw like
    /// `codeBackgroundColor` so it survives a light/dark switch without a
    /// restyle. Falls back to system red, as `Palette.danger` does.
    private static let commandMarkerColor = NSColor(name: nil) { appearance in
        let scheme: ColorScheme =
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        guard let themeColor = ThemeChrome.dangerAccent(for: scheme) else {
            return NSColor.systemRed
        }
        return NSColor(themeColor)
    }
}

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}
