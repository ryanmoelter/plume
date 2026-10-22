#if DEBUG
import AppKit

/// Resolves a substring of on-screen text to the rect it occupies, at glyph
/// precision, so a click can land on a word rather than a control.
@MainActor
enum TextSpanLocator {
    struct Hit {
        /// AppKit window coordinates.
        let rectInWindow: CGRect
        let window: NSWindow?
        let text: String
    }

    /// A text on screen: an AppKit view, or one `Text` of a chat piece that
    /// draws through `ChatSelectionRenderer` and has no view of its own.
    enum Item {
        case view(NSView)
        case chat(ChatListController.SelectableTextFrame, ChatListController)

        var text: String {
            switch self {
            case .view(let view): TextSpanLocator.text(of: view)
            case .chat(let frame, _): frame.text
            }
        }

        /// AppKit window coordinates.
        var rectInWindow: CGRect {
            switch self {
            case .view(let view): view.convert(view.bounds, to: nil)
            case .chat(let frame, _): frame.windowRect
            }
        }

        var window: NSWindow? {
            switch self {
            case .view(let view): view.window
            case .chat(_, let controller): controller.documentView.window
            }
        }

        func isSame(as other: Item) -> Bool {
            switch (self, other) {
            case (.view(let a), .view(let b)): a === b
            case (.chat(let a, _), .chat(let b, _)): a.pieceID == b.pieceID && a.offset == b.offset
            default: false
            }
        }

        func rect(of range: NSRange) -> CGRect? {
            switch self {
            case .view(let view): TextSpanLocator.rect(of: range, in: view)
            case .chat(let frame, let controller):
                controller.windowRect(
                    ofCharacters: range.location..<(range.location + range.length), pieceID: frame.pieceID, offset: frame.offset
                )
            }
        }
    }

    static func locate(_ needle: String, occurrence: Int, in candidates: [NSView]) -> Hit? {
        locate(needle, occurrence: occurrence, in: candidates.map(Item.view))
    }

    /// Searches `candidates` in order for the `occurrence`-th match of
    /// `needle`, counting across items.
    static func locate(_ needle: String, occurrence: Int, in candidates: [Item]) -> Hit? {
        guard !needle.isEmpty else { return nil }
        var remaining = occurrence
        for item in candidates {
            let text = item.text
            var searchStart = text.startIndex
            while let found = text.range(of: needle, range: searchStart..<text.endIndex) {
                if remaining == 0 {
                    guard let rect = item.rect(of: NSRange(found, in: text)) else { return nil }
                    return Hit(rectInWindow: rect, window: item.window, text: text)
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
