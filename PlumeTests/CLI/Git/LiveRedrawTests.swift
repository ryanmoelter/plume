import Foundation
import Testing
@testable import Plume

/// The pure pieces behind `wt list` and `stack list`'s live redraw.
struct LiveRedrawTests {
    @Test func onlyATerminalWithRoomToSpareRedrawsInPlace() {
        #expect(LiveRedraw.redrawsInPlace(isTerminal: true, frameRows: 3, terminalRows: nil))
        #expect(LiveRedraw.redrawsInPlace(isTerminal: true, frameRows: 23, terminalRows: 24))
        #expect(!LiveRedraw.redrawsInPlace(isTerminal: true, frameRows: 24, terminalRows: 24))
        #expect(!LiveRedraw.redrawsInPlace(isTerminal: false, frameRows: 3, terminalRows: 24))
    }

    @Test func visibleWidthIgnoresEscapes() {
        let styled = "\u{1B}[1m\u{1B}[36m日本\u{1B}[0m x"
        let linked = "\u{1B}]8;;https://example.com\u{1B}\\ab\u{1B}]8;;\u{07}"
        #expect(TerminalUI.visibleWidth(styled) == 6)
        #expect(TerminalUI.visibleWidth(linked) == 2)
    }
}
