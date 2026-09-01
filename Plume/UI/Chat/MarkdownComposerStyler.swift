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
    static func style(_ storage: NSTextStorage, text: String, fontSize: CGFloat) {
        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        storage.setAttributes([
            .font: bodyFont,
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)

        for span in MarkdownHighlighter.spans(in: text) {
            guard fullRange.contains(span.range) || span.range.length == 0 else { continue }
            apply(span, to: storage, bodyFontSize: fontSize)
        }
        storage.endEditing()
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
        let base = NSFont.systemFont(ofSize: size)
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
        return NSFont.systemFont(ofSize: bodyFontSize * multiplier, weight: weight)
    }

    /// Matches `MarkdownView.codeBackground`: `ThemeChrome` foreground at 8%
    /// opacity, falling back to system secondary when no theme is set.
    private static var codeBackgroundColor: NSColor {
        if let themeColor = ThemeChrome.foreground(for: currentColorScheme) {
            return NSColor(themeColor).withAlphaComponent(0.08)
        }
        return NSColor.secondaryLabelColor.withAlphaComponent(0.1)
    }

    private static var currentColorScheme: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}
