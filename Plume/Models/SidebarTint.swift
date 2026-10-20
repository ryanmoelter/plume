import Foundation

/// A color a group or task carries in the sidebar.
///
/// A palette slot rather than a color, so a light/dark theme pair gives each
/// appearance its own palette's version of it.
enum SidebarTint: Hashable {
    /// The theme's text color.
    case text
    case palette(slot: Int)

    static let paletteSlots = 0...15

    init?(rawValue: String) {
        if rawValue == "text" {
            self = .text
            return
        }
        let prefix = "palette:"
        guard rawValue.hasPrefix(prefix),
              let slot = Int(rawValue.dropFirst(prefix.count)),
              Self.paletteSlots.contains(slot)
        else { return nil }
        self = .palette(slot: slot)
    }

    var rawValue: String {
        switch self {
        case .text: "text"
        case .palette(let slot): "palette:\(slot)"
        }
    }

    /// A task with no color of its own takes its group's.
    static func effective(for task: WorkTask) -> SidebarTint? {
        task.tint ?? task.group?.tint
    }
}
