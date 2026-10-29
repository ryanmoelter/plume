import AppKit
import Testing
@testable import Plume

/// The mention token being searched is drawn in the accent color while its
/// menu is open, and the text itself never changes.
@MainActor
struct ComposerActiveMentionTintTests {
    private let accent = NSColor.systemPink

    private func styled(_ text: String, activeMention: NSRange?) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownComposerStyler.style(storage, text: text, fontSize: 13, accent: accent, activeMention: activeMention)
        return storage
    }

    private func color(at location: Int, in storage: NSTextStorage) -> NSColor? {
        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    @Test func theActiveRangeTakesTheAccent() {
        let storage = styled("See @file:ab now", activeMention: NSRange(location: 4, length: 8))
        for location in 4..<12 {
            #expect(color(at: location, in: storage) == accent)
        }
        #expect(color(at: 3, in: storage) == .labelColor)
        #expect(color(at: 12, in: storage) == .labelColor)
        #expect(storage.string == "See @file:ab now")
    }

    @Test func noActiveRangeLeavesTheTextPlain() {
        let storage = styled("See @file:ab now", activeMention: nil)
        for location in 0..<16 {
            #expect(color(at: location, in: storage) == .labelColor)
        }
    }

    @Test func aStaleRangePastTheTextIsIgnored() {
        let storage = styled("hi", activeMention: NSRange(location: 1, length: 9))
        #expect(color(at: 1, in: storage) == .labelColor)
    }
}
