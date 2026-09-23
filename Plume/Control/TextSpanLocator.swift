#if DEBUG
import AppKit

/// Resolves a substring of on-screen text to the rect it occupies, at glyph
/// precision, so a click can land on a word rather than a control.
@MainActor
enum TextSpanLocator {
    struct Hit {
        /// AppKit window coordinates.
        let rectInWindow: CGRect
        let view: NSView
        let text: String
    }

    /// Searches `candidates` in order for the `occurrence`-th match of
    /// `needle`, counting across views.
    static func locate(_ needle: String, occurrence: Int, in candidates: [NSView]) -> Hit? {
        guard !needle.isEmpty else { return nil }
        var remaining = occurrence
        for view in candidates {
            let text = Self.text(of: view)
            var searchStart = text.startIndex
            while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
                if remaining == 0 {
                    let range = NSRange(found, in: text)
                    if let rect = rect(of: range, in: view) {
                        return Hit(rectInWindow: rect, view: view, text: text)
                    }
                    return nil
                }
                remaining -= 1
                searchStart = found.upperBound
            }
        }
        return nil
    }

    static func text(of view: NSView) -> String {
        switch view {
        case let textView as NSTextView: textView.string
        case let field as NSTextField: field.attributedStringValue.string
        default: ""
        }
    }

    static func rect(of range: NSRange, in view: NSView) -> CGRect? {
        switch view {
        case let textView as NSTextView: rect(of: range, in: textView)
        case let field as NSTextField: rect(of: range, in: field)
        default: nil
        }
    }

    /// Window coordinates. TextKit 2 is asked first, because reading
    /// `layoutManager` on a TextKit 2 view silently downgrades it.
    static func rect(of range: NSRange, in textView: NSTextView) -> CGRect? {
        var local: CGRect?
        if let layout = textView.textLayoutManager, let content = layout.textContentManager {
            let start = content.documentRange.location
            guard
                let from = content.location(start, offsetBy: range.location),
                let to = content.location(from, offsetBy: range.length),
                let textRange = NSTextRange(location: from, end: to)
            else { return nil }
            layout.ensureLayout(for: textRange)
            layout.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
                local = local.map { $0.union(frame) } ?? frame
                return true
            }
        } else if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            local = layout.boundingRect(forGlyphRange: glyphs, in: container)
        }
        guard var rect = local else { return nil }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.convert(rect, to: nil)
    }

    /// Window coordinates. A live field editor gives the exact rect; without
    /// one the field's text is laid out again in a scratch container the
    /// size of its title rect, which matches to within a point.
    static func rect(of range: NSRange, in field: NSTextField) -> CGRect? {
        if let editor = field.currentEditor() as? NSTextView {
            return rect(of: range, in: editor)
        }
        let titleRect = field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds
        let storage = NSTextStorage(attributedString: field.attributedStringValue)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: titleRect.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        if !field.isFlipped {
            rect.origin.y = titleRect.height - rect.maxY
        }
        rect.origin.x += titleRect.minX
        rect.origin.y += titleRect.minY
        return field.convert(rect, to: nil)
    }
}
#endif
