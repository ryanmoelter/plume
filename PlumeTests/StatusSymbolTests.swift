import AppKit
import Testing
@testable import Plume

/// The symbol vocabulary is shared across the sidebar, the chat, the minimap
/// and the composer, so a name that does not resolve would silently draw
/// nothing in four places at once.
struct StatusSymbolTests {
    @Test func everySymbolExistsInBothForms() {
        for symbol in StatusSymbol.allCases {
            #expect(
                NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) != nil,
                "\(symbol).name is not a system symbol: \(symbol.name)"
            )
            #expect(
                NSImage(systemSymbolName: symbol.filled, accessibilityDescription: nil) != nil,
                "\(symbol).filled is not a system symbol: \(symbol.filled)"
            )
        }
    }

    /// Two concepts sharing a glyph makes the badge ambiguous — `hand.raised`
    /// meaning both "wants permission" and "was interrupted" is what this
    /// vocabulary exists to prevent.
    @Test func noTwoConceptsShareAGlyph() {
        let names = StatusSymbol.allCases.map(\.name)
        #expect(Set(names).count == names.count, "\(names)")
    }

    /// Some symbols are strokes with nothing to fill, so `filled` returns them
    /// unchanged rather than naming a symbol that does not exist — which would
    /// draw nothing at all.
    @Test func aSymbolWithNoFillVariantStandsAsItself() {
        #expect(StatusSymbol.awaitingReply.filled == StatusSymbol.awaitingReply.name)
        #expect(StatusSymbol.remoteControl.filled == StatusSymbol.remoteControl.name)
    }
}
