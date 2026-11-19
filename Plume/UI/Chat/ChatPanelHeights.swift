import Foundation

/// The floating bottom chrome's last measured height per tab, so a chat that
/// remounts on a task switch insets its first frame correctly. Per tab because
/// the chrome's height differs between tabs, and split panes mount chats side
/// by side.
@MainActor
enum ChatPanelHeights {
    private static var heights: [UUID: CGFloat] = [:]

    static func height(forTab tabID: UUID) -> CGFloat {
        heights[tabID] ?? 0
    }

    static func record(_ height: CGFloat, forTab tabID: UUID) {
        heights[tabID] = height
    }

    static func forget(tabID: UUID) {
        heights[tabID] = nil
    }
}
