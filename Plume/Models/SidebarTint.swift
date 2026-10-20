import SwiftUI

/// A color a group or task carries in the sidebar.
///
/// A palette slot rather than a color, so a light/dark theme pair gives each
/// appearance its own palette's version of it.
enum SidebarTint: Hashable {
    /// The theme's text color.
    case text
    case palette(slot: Int)

    init?(rawValue: String) {
        if rawValue == "text" {
            self = .text
            return
        }
        let prefix = "palette:"
        guard rawValue.hasPrefix(prefix),
              let slot = Int(rawValue.dropFirst(prefix.count)),
              ThemeChrome.paletteSlots.contains(slot)
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

/// The icons the popover offers, and which custom ones it remembers.
enum SidebarIcons {
    static let curated = [
        "folder", "star", "flag", "bookmark", "tag", "bolt",
        "flame", "leaf", "ladybug", "hammer", "wrench.and.screwdriver", "paintbrush",
        "doc.text", "book", "lightbulb", "sparkles", "globe", "server.rack",
        "terminal", "cpu", "shippingbox", "cube", "testtube.2", "heart",
    ]
    static let recentLimit = 12

    /// `recent` with a custom `icon` moved to the front, deduplicated and capped.
    static func recording(_ icon: String?, in recent: [String]) -> [String] {
        guard let icon, !curated.contains(icon) else { return recent }
        return Array(([icon] + recent.filter { $0 != icon }).prefix(recentLimit))
    }

}

/// Where a task's color shows, given the sidebar settings. A nil tint means
/// that part renders untinted.
struct SidebarTaskAppearance: Equatable {
    let barTint: SidebarTint?
    let dotTint: SidebarTint?
    let iconTint: SidebarTint?
    let titleTint: SidebarTint?
    let weight: Font.Weight

    init(
        effective: SidebarTint?,
        marker: SidebarTaskMarker,
        colorsNames: Bool,
        tintsIcons: Bool,
        bold: Bool,
        hasIcon: Bool
    ) {
        barTint = marker == .bar ? effective : nil
        dotTint = marker == .dot && !hasIcon ? effective : nil
        iconTint = tintsIcons ? effective : nil
        titleTint = colorsNames ? effective : nil
        weight = bold ? .bold : .regular
    }

    init(task: WorkTask, settings: AppSettings) {
        self.init(
            effective: SidebarTint.effective(for: task),
            marker: settings.sidebarTaskMarker,
            colorsNames: settings.sidebarColorsTaskNames,
            tintsIcons: settings.sidebarTintsTaskIcons,
            bold: settings.sidebarBoldTaskNames,
            hasIcon: task.iconName != nil
        )
    }
}
