import AppKit
import SwiftUI

/// A color a group or task carries in the sidebar.
///
/// A palette slot or extended-palette hue rather than a resolved color, so a
/// light/dark theme pair gives each appearance its own palette's version of it.
enum SidebarTint: Hashable {
    /// The theme's text color.
    case text
    case palette(slot: Int)
    /// A hue from the extended palette, in its text or its bright variant.
    case extended(ExtendedHue, bright: Bool)

    init?(rawValue: String) {
        if rawValue == "text" {
            self = .text
            return
        }
        if let extended = Self.extended(rawValue: rawValue) {
            self = extended
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
        case .extended(let hue, let bright): "extended:\(bright ? "bright" : "text"):\(hue.rawValue)"
        }
    }

    private static func extended(rawValue: String) -> SidebarTint? {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "extended",
              let hue = ExtendedHue(rawValue: String(parts[2]))
        else { return nil }
        switch parts[1] {
        case "text": return .extended(hue, bright: false)
        case "bright": return .extended(hue, bright: true)
        default: return nil
        }
    }

    /// The tint for one swatch of the extended palette.
    static func wheel(_ hue: PaletteHue, bright: Bool) -> SidebarTint {
        switch hue {
        case .slot(let slot): .palette(slot: bright ? slot + 8 : slot)
        case .extended(let hue): .extended(hue, bright: bright)
        }
    }

    var isExtended: Bool {
        if case .extended = self { true } else { false }
    }

    /// What a picker calls this color.
    var name: String { name(lum: false) }

    /// With `lum`, slots 1–6 and their bright variants take Lum's own names.
    func name(lum: Bool) -> String {
        switch self {
        case .text: "Text"
        case .palette(let slot):
            if lum, let hue = ThemeChrome.lumSlotNames[slot > 8 ? slot - 8 : slot] {
                slot > 8 ? "Bright \(hue)" : hue
            } else {
                ThemeChrome.paletteSlotNames[slot]
            }
        case .extended(let hue, let bright): bright ? "Bright \(hue.name)" : hue.name
        }
    }

    /// A task with no color of its own takes its group's.
    static func effective(for task: WorkTask) -> SidebarTint? {
        task.tint ?? task.group?.tint
    }
}

/// The icons the popover offers, and which custom ones it remembers.
enum SidebarIcons {
    static let columns = 8
    static let popular = [
        "folder", "doc.text", "book", "bookmark", "flag", "star", "heart", "sparkles",
        "bolt", "flame", "leaf", "ladybug", "lightbulb", "house", "person.2", "globe",
        "pencil.line", "paintbrush", "hammer", "wrench.and.screwdriver", "gearshape", "testtube.2", "shippingbox", "cube",
        "terminal", "cpu", "server.rack", "cloud", "desktopcomputer", "laptopcomputer", "ipad", "iphone",
    ]
    static let recentLimit = popular.count

    /// `popular` with each icon swapped for its `.fill` variant where the OS has one.
    static let popularFilled: [String] = popular.map(filledVariant(of:))

    static func filledVariant(of name: String) -> String {
        let filled = name + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : name
    }

    /// Always explicit: a symbol with a preferred two-tone mode takes it when none is set.
    static func renderingMode(twoTone: Bool) -> SymbolRenderingMode {
        twoTone ? .hierarchical : .monochrome
    }

    static func popular(filled: Bool) -> [String] {
        filled ? popularFilled : popular
    }

    private static let allPopular = Set(popular + popularFilled)

    /// `recent` with a custom `icon` moved to the front, deduplicated and capped.
    static func recording(_ icon: String?, in recent: [String]) -> [String] {
        guard let icon, !allPopular.contains(icon) else { return recent }
        return Array(([icon] + recent.filter { $0 != icon }).prefix(recentLimit))
    }
}

/// The sample row in Settings, which colors with the app's accent.
enum SidebarPreviewTint {
    /// `.text` stands in for the system accent, which has no palette color;
    /// `color(...)` resolves it.
    static func effective(accent: SidebarTint?) -> SidebarTint {
        accent ?? .text
    }

    static func color(for tint: SidebarTint, accent: SidebarTint?, theme: Theme) -> Color? {
        accent == nil ? .accentColor : theme.colors.color(for: tint)
    }
}

/// Where a task's color shows, given the sidebar settings. A nil tint means
/// that part renders untinted.
struct SidebarTaskAppearance: Equatable {
    let barTint: SidebarTint?
    let iconTint: SidebarTint?
    let titleTint: SidebarTint?
    let weight: Font.Weight

    init(
        effective: SidebarTint?,
        showsBar: Bool,
        colorsNames: Bool,
        colorsIcons: Bool,
        bold: Bool
    ) {
        barTint = showsBar ? effective : nil
        iconTint = colorsIcons ? effective : nil
        titleTint = colorsNames ? effective : nil
        weight = bold ? .bold : .regular
    }

    init(task: WorkTask, settings: AppSettings) {
        self.init(
            effective: SidebarTint.effective(for: task),
            showsBar: settings.sidebarShowsTaskColorBar,
            colorsNames: settings.sidebarColorsTaskNames,
            colorsIcons: settings.sidebarColorsTaskIcons,
            bold: settings.sidebarBoldTaskNames
        )
    }
}
