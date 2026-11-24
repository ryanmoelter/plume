import AppKit

/// What the transcript shows under the pointer, set from the document view's
/// own tracking area on every move so it never waits on SwiftUI's pointer
/// updates, which lag behind a move between rows.
enum ChatPointerKind: Equatable {
    case text
    case link
    /// A gap between rows, or a markdown row away from its text.
    case plain
    /// Off the transcript, or over a row that keeps SwiftUI's own selection
    /// and controls, whose cursor is that row's to set.
    case unowned

    var cursor: NSCursor? {
        switch self {
        case .text: .iBeam
        case .link: .pointingHand
        case .plain: .arrow
        case .unowned: nil
        }
    }
}

struct ChatPointerCursor {
    private(set) var current: ChatPointerKind = .unowned

    /// The cursor to set on a move to `kind`. Moving from text or a link to
    /// somewhere unowned sets the arrow once, so the I-beam never lingers
    /// over the tab bar or a tool row, and then leaves the cursor alone.
    mutating func move(to kind: ChatPointerKind) -> NSCursor? {
        defer { current = kind }
        if kind == .unowned {
            return current == .text || current == .link ? .arrow : nil
        }
        return kind.cursor
    }
}
