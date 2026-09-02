import Testing
import Foundation
@testable import Plume

/// Arrow-key stepping, which the sidebar took over from `List` when the rows
/// disabled its selection.
struct SidebarKeyboardNavigationTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private var ordered: [UUID] { [a, b, c] }

    @Test func downMovesToTheNextTask() {
        #expect(SidebarKeyboardNavigation.destination(from: a, in: ordered, offset: 1) == b)
    }

    @Test func upMovesToThePreviousTask() {
        #expect(SidebarKeyboardNavigation.destination(from: c, in: ordered, offset: -1) == b)
    }

    /// Staying put at the ends, rather than wrapping, is what `List` did.
    @Test func theEndsDoNotWrap() {
        #expect(SidebarKeyboardNavigation.destination(from: c, in: ordered, offset: 1) == nil)
        #expect(SidebarKeyboardNavigation.destination(from: a, in: ordered, offset: -1) == nil)
    }

    @Test func nothingSelectedSelectsTheFirstTask() {
        #expect(SidebarKeyboardNavigation.destination(from: nil, in: ordered, offset: 1) == a)
        #expect(SidebarKeyboardNavigation.destination(from: nil, in: ordered, offset: -1) == a)
    }

    /// A selection for a task that is gone (deleted, archived, filtered out).
    @Test func anUnknownSelectionFallsBackToTheFirstTask() {
        #expect(SidebarKeyboardNavigation.destination(from: UUID(), in: ordered, offset: 1) == a)
    }

    @Test func anEmptySidebarHasNowhereToGo() {
        #expect(SidebarKeyboardNavigation.destination(from: nil, in: [], offset: 1) == nil)
    }
}
