import CoreGraphics
import Foundation

/// Where the reader left a chat: at the top, at the bottom, or scrolled to an item.
enum ChatReadingPosition: Equatable {
    case bottom
    /// The first item at the viewport's top edge.
    case top
    /// The item under the viewport's top edge, and how far into its slot the
    /// viewport's top sits.
    case anchor(id: String, distance: CGFloat)
}

/// Each tab's reading position, so a chat that comes back on screen opens
/// where the reader left it. A hidden chat tab is unmounted, which takes its
/// list controller with it; this outlives the controller. Memory only.
@MainActor
final class ChatReadingPositions {
    static let shared = ChatReadingPositions()

    private var positions: [UUID: ChatReadingPosition] = [:]

    subscript(tabID: UUID) -> ChatReadingPosition? {
        get { positions[tabID] }
        set { positions[tabID] = newValue }
    }
}
