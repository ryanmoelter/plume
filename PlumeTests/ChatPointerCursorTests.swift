import AppKit
import Testing
@testable import Plume

/// The transcript sets the cursor on every move it owns, and on leaving text
/// for somewhere it doesn't own sets the arrow exactly once.
@MainActor
struct ChatPointerCursorTests {
    @Test func ownedKindsSetTheirCursorOnEveryMove() {
        var cursor = ChatPointerCursor()
        #expect(cursor.move(to: .text) === NSCursor.iBeam)
        #expect(cursor.move(to: .text) === NSCursor.iBeam)
        #expect(cursor.move(to: .link) === NSCursor.pointingHand)
        #expect(cursor.move(to: .plain) === NSCursor.arrow)
        #expect(cursor.move(to: .plain) === NSCursor.arrow)
    }

    @Test func leavingTextForUnownedSetsTheArrowOnce() {
        var cursor = ChatPointerCursor()
        _ = cursor.move(to: .text)
        #expect(cursor.move(to: .unowned) === NSCursor.arrow)
        #expect(cursor.move(to: .unowned) == nil)
    }

    @Test func leavingALinkForUnownedSetsTheArrow() {
        var cursor = ChatPointerCursor()
        _ = cursor.move(to: .link)
        #expect(cursor.move(to: .unowned) === NSCursor.arrow)
    }

    @Test func unownedAfterAGapLeavesTheCursorToTheRow() {
        var cursor = ChatPointerCursor()
        #expect(cursor.move(to: .unowned) == nil)
        _ = cursor.move(to: .plain)
        #expect(cursor.move(to: .unowned) == nil)
    }
}
