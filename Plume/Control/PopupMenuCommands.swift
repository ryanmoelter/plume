#if DEBUG
import AppKit

/// Opens the menu under a control with a click, or the control's `invoke`
/// closure when it registered one.
nonisolated struct MenuOpenParams: Decodable, Equatable {
    var target: ControlTarget?
    var x: Double?
    var y: Double?
    var windowNumber: Int?
    var timeout: Double = 2

    private enum CodingKeys: String, CodingKey { case target, x, y, windowNumber, timeout }

    init(target: ControlTarget? = nil, x: Double? = nil, y: Double? = nil, windowNumber: Int? = nil, timeout: Double = 2) {
        self.target = target
        self.x = x
        self.y = y
        self.windowNumber = windowNumber
        self.timeout = timeout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decodeIfPresent(ControlTarget.self, forKey: .target)
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        windowNumber = try c.decodeIfPresent(Int.self, forKey: .windowNumber)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 2
    }

    func validate() throws {
        switch (target, x, y) {
        case (.some, nil, nil), (nil, .some, .some): break
        case (.some, _, _): throw ControlError.badParams("menu.open takes target or x and y, not both")
        default: throw ControlError.badParams("menu.open needs a target, or x and y")
        }
    }
}

/// `item` is a path (`Sort > Newest`), a title, or a substring of one path.
nonisolated struct MenuPickParams: Decodable, Equatable {
    var item: String
}

nonisolated struct MenuScreenshotParams: Decodable, Equatable {
    var path: String?
}

nonisolated struct PopupMenuItemDescription: Codable, Equatable {
    var path: String
    var isEnabled: Bool
    /// `on` or `mixed` for a checked item; absent otherwise.
    var state: String?
    var hasSubmenu: Bool
}

nonisolated struct PopupMenuResult: Codable, Equatable {
    var items: [PopupMenuItemDescription]
    /// The item `menu.pick` ran, when it ran one.
    var picked: String?
}

/// Resolves `menu.pick`'s `item` against an open menu's item paths: an exact
/// path first, then an exact title, then a case-insensitive substring of
/// one path. Each tier must match exactly one item.
nonisolated enum PopupMenuItemMatch {
    static let separator = " > "

    static func index(of query: String, in paths: [String]) throws -> Int {
        let tiers: [(String) -> Bool] = [
            { $0 == query },
            { $0.components(separatedBy: separator).last == query },
            { $0.range(of: query, options: .caseInsensitive) != nil },
        ]
        for matches in tiers {
            let hits = paths.indices.filter { matches(paths[$0]) }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw ControlError.ambiguous("menu item \"\(query)\"", count: hits.count) }
        }
        throw ControlError.notFound("menu item \"\(query)\" in \(paths)")
    }
}

/// `menu.open`, `menu.items`, `menu.pick`, `menu.close` and `menu.screenshot`:
/// a popup menu's items mount only while AppKit tracks it, so these read and
/// pick from the menu `PopupMenuTracker` saw open.
extension InProcessControlBackend {
    func openMenu(_ params: MenuOpenParams) async throws -> PopupMenuResult {
        try params.validate()
        guard PopupMenuTracker.shared.open.isEmpty else {
            throw ControlError.unsupported("a menu is already open; menu.close it first")
        }
        if let target = params.target {
            _ = try await invoke(target)
        } else if let x = params.x, let y = params.y {
            _ = try await click(ClickParams(x: x, y: y, windowNumber: params.windowNumber))
        }
        let deadline = ContinuousClock.now + .seconds(max(params.timeout, 0.1))
        while PopupMenuTracker.shared.open.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard PopupMenuTracker.shared.open.last != nil else {
            // SwiftUI never starts presenting a menu from a window that is
            // not on screen.
            let hidden = NSApp.isHidden ? "; a hidden app (open -j) opens no menus, relaunch without -j" : ""
            throw ControlError.notFound("a menu opened within \(params.timeout)s\(hidden)")
        }
        return try menuItems()
    }

    func menuItems() throws -> PopupMenuResult {
        PopupMenuResult(items: Self.flatten(try openPopupMenu()).map(\.description), picked: nil)
    }

    /// Ends tracking first, as choosing an item does, then sends the item's
    /// action. The item's target is read before tracking ends, because a
    /// SwiftUI menu may rebuild its items when it closes.
    func pickMenuItem(_ params: MenuPickParams) async throws -> PopupMenuResult {
        let root = try openPopupMenu()
        let entries = Self.flatten(root)
        let entry = entries[try PopupMenuItemMatch.index(of: params.item, in: entries.map(\.description.path))]
        let item = entry.item
        guard item.isEnabled else { throw ControlError.unsupported("menu item \"\(entry.description.path)\" is disabled") }
        guard let action = item.action else {
            throw ControlError.unsupported("menu item \"\(entry.description.path)\" has no action; pick an item of its submenu")
        }
        let target = item.target
        await closeMenus()
        NSApp.sendAction(action, to: target, from: item)
        return PopupMenuResult(items: entries.map(\.description), picked: entry.description.path)
    }

    func closeMenus() async {
        for menu in PopupMenuTracker.shared.open.reversed() { menu.cancelTrackingWithoutAnimation() }
        let deadline = ContinuousClock.now + .seconds(1)
        while !PopupMenuTracker.shared.open.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The newest popup-menu window this process has. AppKit keeps an
    /// earlier menu's window around, off screen, and a window on another
    /// Space reads off screen too, so the newest wins over on-screen state.
    func menuScreenshot(_ params: MenuScreenshotParams) throws -> ScreenshotResult {
        _ = try openPopupMenu()
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let pid = Int(getpid())
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = windows
            .filter({ ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == level })
            .max(by: { ($0[kCGWindowNumber as String] as? Int ?? 0) < ($1[kCGWindowNumber as String] as? Int ?? 0) }),
            let number = info[kCGWindowNumber as String] as? Int
        else {
            throw ControlError.notFound("a menu window")
        }
        guard let image = WindowCapture.image(windowID: UInt32(number)) else {
            throw ControlError.io("the window server has no image of the menu (\(WindowCapture.displayState))")
        }
        let points = (info[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? Double(image.width)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ControlError.io("could not encode PNG")
        }
        let path = params.path ?? NSTemporaryDirectory() + "plume-menu-\(Int(Date().timeIntervalSince1970)).png"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path))
        return ScreenshotResult(path: path, width: image.width, height: image.height, scale: Double(image.width) / max(points, 1))
    }

    private func openPopupMenu() throws -> NSMenu {
        guard let menu = PopupMenuTracker.shared.open.last else { throw ControlError.notFound("an open menu; menu.open one first") }
        return menu
    }

    private struct FlatItem {
        let item: NSMenuItem
        let description: PopupMenuItemDescription
    }

    private static func flatten(_ menu: NSMenu, prefix: [String] = []) -> [FlatItem] {
        menu.update()
        var flat: [FlatItem] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            let path = prefix + [item.title]
            let state: String? = switch item.state {
            case .on: "on"
            case .mixed: "mixed"
            default: nil
            }
            flat.append(FlatItem(item: item, description: PopupMenuItemDescription(
                path: path.joined(separator: PopupMenuItemMatch.separator),
                isEnabled: item.isEnabled, state: state, hasSubmenu: item.submenu != nil
            )))
            if let submenu = item.submenu { flat += flatten(submenu, prefix: path) }
        }
        return flat
    }
}
#endif
