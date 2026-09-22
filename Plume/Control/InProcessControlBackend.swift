#if DEBUG
import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Answers control commands from inside the process: registered controls
/// through `ControlRegistry`, text through the AppKit views that already
/// back the composer and the chat list, clicks through `SyntheticClick`.
/// Nothing here activates the app or moves the pointer.
@MainActor
final class InProcessControlBackend: ControlBackend {
    private let registry: ControlRegistry

    init(registry: ControlRegistry = .shared) {
        self.registry = registry
    }

    // MARK: Controls

    func list(_ params: ListParams) throws -> [ControlDescription] {
        registry.entries(id: params.plumeID, label: params.label, windowNumber: params.windowNumber).map(describe)
    }

    func describe(_ target: ControlTarget) throws -> ControlDescription {
        let entry = try registry.resolve(target)
        let index = registry.entries(id: entry.id).first { $0.entry.token == entry.token }?.index ?? 0
        return describe((index, entry))
    }

    private func describe(_ match: (index: Int, entry: ControlEntry)) -> ControlDescription {
        let entry = match.entry
        return ControlDescription(
            id: entry.id, index: match.index, label: entry.label, value: entry.value, isEnabled: entry.isEnabled,
            frame: Rect(entry.frame), windowNumber: entry.window?.windowNumber,
            hasInvoke: entry.invoke != nil, hasSetValue: entry.setValue != nil
        )
    }

    func invoke(_ target: ControlTarget) async throws -> InvokeResult {
        let entry = try registry.resolve(target)
        guard entry.isEnabled else { throw ControlError.unsupported("\(target) is disabled") }
        if let invoke = entry.invoke {
            invoke()
            return InvokeResult(via: "closure")
        }
        let window = try window(for: entry)
        let point = WindowGeometry.appKitPoint(
            fromTopLeft: CGPoint(x: entry.frame.midX, y: entry.frame.midY), contentHeight: contentHeight(of: window)
        )
        await SyntheticClick.perform(at: point, in: window)
        return InvokeResult(via: "click")
    }

    func setValue(_ target: ControlTarget, value: String) throws {
        switch target {
        case .composer:
            let composer = try composerTextView()
            composer.string = value
            composer.didChangeText()
        case .control:
            let entry = try registry.resolve(target)
            guard let setValue = entry.setValue else { throw ControlError.unsupported("\(target) has no setValue") }
            setValue(value)
        case .chatList, .window:
            throw ControlError.unsupported("\(target) holds no value")
        }
    }

    // MARK: Text

    func readText(_ target: ControlTarget) throws -> TextResult {
        switch target {
        case .composer:
            return TextResult(text: try composerTextView().string, rows: nil)
        case .chatList:
            let rows = try chatListTextViews().map(TextSpanLocator.text(of:)).filter { !$0.isEmpty }
            return TextResult(text: rows.joined(separator: "\n"), rows: rows.enumerated().map { TextRow(index: $0.offset, text: $0.element) })
        case .window:
            let window = try window(for: nil)
            let rows = textViews(in: window.contentView!).map(TextSpanLocator.text(of:)).filter { !$0.isEmpty }
            return TextResult(text: rows.joined(separator: "\n"), rows: rows.enumerated().map { TextRow(index: $0.offset, text: $0.element) })
        case .control:
            let entry = try registry.resolve(target)
            if let value = entry.value { return TextResult(text: value, rows: nil) }
            let rows = try textViews(within: entry).map(TextSpanLocator.text(of:)).filter { !$0.isEmpty }
            if rows.isEmpty, let label = entry.label { return TextResult(text: label, rows: nil) }
            return TextResult(text: rows.joined(separator: "\n"), rows: nil)
        }
    }

    // MARK: Clicks

    func clickSpan(_ params: ClickSpanParams) async throws -> ClickResult {
        let candidates = try textCandidates(for: params.target)
        guard let hit = TextSpanLocator.locate(params.matching, occurrence: params.occurrence, in: candidates) else {
            throw ControlError.spanNotFound(params.matching)
        }
        guard let window = hit.view.window else { throw ControlError.noWindow }
        await SyntheticClick.perform(at: CGPoint(x: hit.rectInWindow.midX, y: hit.rectInWindow.midY), in: window)
        let rect = WindowGeometry.topLeftRect(fromAppKit: hit.rectInWindow, contentHeight: contentHeight(of: window))
        return ClickResult(rect: Rect(rect), windowNumber: window.windowNumber)
    }

    func click(_ params: ClickParams) async throws -> ClickResult {
        let window = try window(for: params.windowNumber)
        let point = WindowGeometry.appKitPoint(fromTopLeft: CGPoint(x: params.x, y: params.y), contentHeight: contentHeight(of: window))
        await SyntheticClick.perform(at: point, in: window, clickCount: params.clickCount)
        return ClickResult(rect: Rect(CGRect(x: params.x, y: params.y, width: 0, height: 0)), windowNumber: window.windowNumber)
    }

    // MARK: Pointer

    func hover(_ params: HoverParams) async throws -> HoverResult {
        let window = try window(for: params.windowNumber, target: params.target)
        let height = contentHeight(of: window)
        let rect: CGRect
        if let x = params.x, let y = params.y {
            rect = CGRect(x: x, y: y, width: 0, height: 0)
        } else if let target = params.target {
            guard let frame = try frame(of: target) else { throw ControlError.badParams("hover needs a control, or x and y") }
            rect = frame
        } else {
            throw ControlError.badParams("hover needs a target, or x and y")
        }
        let point = WindowGeometry.appKitPoint(fromTopLeft: CGPoint(x: rect.midX, y: rect.midY), contentHeight: height)
        SyntheticHover.move(to: point, in: window)
        return HoverResult(rect: Rect(rect), windowNumber: window.windowNumber, regions: HoverRegistry.shared.hoveredCount)
    }

    func clear(_ params: ClearParams) async throws {
        let windows: [NSWindow] = if let number = params.windowNumber {
            [try window(for: number)]
        } else {
            NSApp.windows.filter { ControlOverlay.existing(for: $0) != nil }
        }
        for window in windows {
            SyntheticHover.leave(window)
            ControlOverlay.existing(for: window)?.remove()
        }
    }

    // MARK: Drag

    func drag(_ params: DragParams) async throws -> DragResult {
        let window = try window(for: params.windowNumber, target: params.target)
        let height = contentHeight(of: window)
        let topLeft: CGPoint
        if let x = params.x, let y = params.y {
            topLeft = CGPoint(x: x, y: y)
        } else if let target = params.target {
            guard let frame = try frame(of: target) else { throw ControlError.badParams("drag needs a control, or x and y") }
            topLeft = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            let destinations = SyntheticDrag.allDestinations(in: window).map { view, types in
                DragDestination(
                    view: String(describing: type(of: view)),
                    frame: Rect(WindowGeometry.topLeftRect(fromAppKit: view.convert(view.bounds, to: nil), contentHeight: height)),
                    types: types
                )
            }
            return DragResult(dropped: false, refusedAt: "noPoint", view: nil, destinations: destinations)
        }

        let pasteboard = SyntheticDraggingInfo.makePasteboard()
        var types: [NSPasteboard.PasteboardType] = []
        if let files = params.files, !files.isEmpty {
            pasteboard.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
            types.append(.fileURL)
        }
        if let text = params.text {
            // SwiftUI reads a `Transferable` payload off the item's data, so
            // the item carries both `public.utf8-plain-text` and the legacy
            // string type an `NSString` write would produce on its own.
            let item = NSPasteboardItem()
            item.setData(Data(text.utf8), forType: .init(UTType.utf8PlainText.identifier))
            item.setString(text, forType: .string)
            pasteboard.writeObjects([item])
            types.append(.string)
        }
        guard !types.isEmpty else { throw ControlError.badParams("drag needs files or text") }

        let point = WindowGeometry.appKitPoint(fromTopLeft: topLeft, contentHeight: height)
        SyntheticHover.move(to: point, in: window)
        guard let destination = SyntheticDrag.destination(at: point, in: window, types: types) else {
            return DragResult(dropped: false, refusedAt: "noDestination", view: nil)
        }
        if params.inApp == true, let text = params.text, let item = SidebarDragItem(payload: text) {
            InAppDrag.shared.begin(item)
        }
        let info = SyntheticDraggingInfo(pasteboard: pasteboard, location: point, window: window)
        var feedback: [String]?
        let outcome = SyntheticDrag.perform(info, on: destination) { feedback = Self.inAppDragFeedback() }
        return DragResult(
            dropped: outcome.succeeded,
            refusedAt: outcome.refusedAt,
            view: String(describing: type(of: destination)),
            entered: Self.names(outcome.entered),
            updated: outcome.updated.map(Self.names),
            prepared: outcome.prepared,
            performed: outcome.performed,
            feedbackAfterUpdate: feedback,
            feedbackAfterDrop: outcome.performed == nil ? nil : Self.inAppDragFeedback()
        )
    }

    private static func inAppDragFeedback() -> [String] {
        let drag = InAppDrag.shared
        var out: [String] = []
        if let item = drag.item { out.append("item \(item.payload)") }
        if let indicator = drag.sidebarIndicator { out.append("sidebar \(indicator.target) \(indicator.placement)") }
        if let gap = drag.tabStripGap { out.append("tabStrip gap \(gap.gap)") }
        return out
    }

    private static func names(_ operation: NSDragOperation) -> [String] {
        var out: [String] = []
        if operation.contains(.copy) { out.append("copy") }
        if operation.contains(.move) { out.append("move") }
        if operation.contains(.link) { out.append("link") }
        if operation.contains(.generic) { out.append("generic") }
        if operation.contains(.delete) { out.append("delete") }
        return out
    }

    // MARK: Keyboard

    func key(_ params: KeyParams) async throws -> KeyResult {
        let shortcut = try Self.shortcut(from: params)
        let window = try window(for: params.windowNumber)
        guard let code = SyntheticKey.keyCode(for: shortcut.key) else {
            throw ControlError.badParams("no key on this layout types \"\(shortcut.key)\"")
        }
        let item = Self.menuItem(matching: shortcut)
        try await SyntheticKey.perform(shortcut, in: window)
        return KeyResult(
            chord: shortcut.displayName, keyCode: Int(code), windowNumber: window.windowNumber,
            handledBy: item.map(Self.path(of:)), handledByEnabled: item?.isEnabled
        )
    }

    func menu() throws -> MenuResult {
        guard let main = NSApp.mainMenu else { throw ControlError.notFound("main menu") }
        var items: [MenuItemDescription] = []
        func visit(_ menu: NSMenu) {
            // AppKit recomputes enabled state only when a menu opens, which a
            // hidden instance never does, so every item would read disabled.
            menu.update()
            for item in menu.items {
                if !item.isSeparatorItem {
                    items.append(
                        MenuItemDescription(
                            path: Self.path(of: item),
                            keyEquivalent: item.keyEquivalent.isEmpty ? nil : item.keyEquivalent,
                            modifiers: Self.modifierNames(item.keyEquivalentModifierMask),
                            isEnabled: item.isEnabled
                        )
                    )
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        visit(main)
        return MenuResult(items: items)
    }

    private static func shortcut(from params: KeyParams) throws -> MenuShortcut {
        guard params.key.count == 1, let key = params.key.first else {
            throw ControlError.badParams("key must be a single character, got \"\(params.key)\"")
        }
        var modifiers: EventModifiers = []
        for name in params.modifiers {
            switch name {
            case "command", "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "alt": modifiers.insert(.option)
            case "control", "ctrl": modifiers.insert(.control)
            default: throw ControlError.badParams("unknown modifier \"\(name)\"")
            }
        }
        return MenuShortcut(key, modifiers: modifiers)
    }

    /// The menu item carrying this chord, matched by key equivalent and
    /// modifier mask rather than by title. Enabled state is reported
    /// separately: `performKeyEquivalent` re-validates as it dispatches, so an
    /// item can answer a chord that reads disabled here.
    private static func menuItem(matching shortcut: MenuShortcut) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        let wanted = MenuShortcut.appKitFlags(shortcut.modifiers)
        func search(_ menu: NSMenu) -> NSMenuItem? {
            menu.update()
            for item in menu.items {
                if item.keyEquivalent.lowercased() == String(shortcut.key).lowercased(),
                   MenuShortcut.deviceIndependentFlags(item.keyEquivalentModifierMask) == wanted {
                    return item
                }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        return search(main)
    }

    private static func path(of item: NSMenuItem) -> String {
        var components = [item.title]
        var menu = item.menu
        while let current = menu, let parent = current.supermenu {
            if let owner = parent.items.first(where: { $0.submenu === current }) {
                components.insert(owner.title, at: 0)
            }
            menu = parent
        }
        return components.joined(separator: " > ")
    }

    private static func modifierNames(_ mask: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if mask.contains(.control) { names.append("control") }
        if mask.contains(.option) { names.append("option") }
        if mask.contains(.shift) { names.append("shift") }
        if mask.contains(.command) { names.append("command") }
        return names
    }

    // MARK: Screenshot

    func screenshot(_ params: ScreenshotParams) throws -> ScreenshotResult {
        let window = try window(for: params.windowNumber, target: params.target)
        guard let content = window.contentView else { throw ControlError.noWindow }
        guard let captured = WindowCapture.image(of: window) else {
            throw ControlError.io("the window server has no image of this window; a hidden app (open -j) cannot be captured, relaunch without -j (\(WindowCapture.displayState))")
        }
        let scale = Double(captured.width) / Double(window.frame.width)
        let contentInWindow = content.convert(content.bounds, to: nil)
        let contentRect = CGRect(
            x: contentInWindow.minX * scale, y: (window.frame.height - contentInWindow.maxY) * scale,
            width: contentInWindow.width * scale, height: contentInWindow.height * scale
        ).integral
        guard var image = captured.cropping(to: contentRect) else { throw ControlError.io("could not crop to the content view") }
        if WindowCapture.isUniform(image) {
            throw ControlError.io("captured a blank window (\(WindowCapture.displayState))")
        }
        if let overlay = ControlOverlay.existing(for: window), let cursor = WindowCapture.image(of: overlay.panel) {
            image = WindowCapture.composite(cursor, over: image) ?? image
        }
        if let target = params.target, let crop = try cropRect(for: target, scale: scale) {
            guard let cropped = image.cropping(to: crop) else { throw ControlError.io("could not crop to \(target)") }
            image = cropped
        }
        let out = NSBitmapImageRep(cgImage: image)
        guard let png = out.representation(using: .png, properties: [:]) else { throw ControlError.io("could not encode PNG") }
        let path = params.path ?? defaultScreenshotPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path))
        return ScreenshotResult(path: path, width: image.width, height: image.height, scale: scale)
    }

    private func cropRect(for target: ControlTarget, scale: Double) throws -> CGRect? {
        guard let frame = try frame(of: target) else { return nil }
        return CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
    }

    /// Fractional seconds, so two shots in one second do not overwrite each other.
    private func defaultScreenshotPath() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return AppPaths.controlDirectory.appending(path: "screenshots/\(stamp).png").path(percentEncoded: false)
    }

    // MARK: Hierarchy

    func hierarchy(_ params: HierarchyParams) throws -> HierarchyResult {
        let window = try window(for: params.windowNumber, target: params.target)
        guard let content = window.contentView else { throw ControlError.noWindow }
        let root = try params.target.map { try rootView(for: $0, in: content) } ?? content
        let node = HierarchyDumper.dump(
            root: root,
            controls: registry.entries(windowNumber: window.windowNumber),
            contentHeight: contentHeight(of: window),
            textLimit: params.textLimit
        )
        switch params.format {
        case .text: return HierarchyResult(text: HierarchyDumper.render(node), root: nil)
        case .json: return HierarchyResult(text: nil, root: node)
        }
    }

    // MARK: Lookup

    private func window(for windowNumber: Int?, target: ControlTarget? = nil) throws -> NSWindow {
        if let windowNumber {
            guard let window = NSApp.windows.first(where: { $0.windowNumber == windowNumber }) else {
                throw ControlError.notFound("window \(windowNumber)")
            }
            return window
        }
        if case .control? = target, let entry = try? registry.resolve(target!), let window = entry.window {
            return window
        }
        // A scratch instance launched hidden (`open -j`) has no visible
        // window, and driving it is the point, so fall back to the largest.
        let candidates = NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 300 }
        guard let window = NSApp.keyWindow
            ?? candidates.first(where: \.isVisible)
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { throw ControlError.noWindow }
        return window
    }

    private func window(for entry: ControlEntry) throws -> NSWindow {
        if let window = entry.window { return window }
        return try window(for: nil)
    }

    private func contentHeight(of window: NSWindow) -> CGFloat {
        window.contentView?.bounds.height ?? window.frame.height
    }

    private func composerTextView() throws -> ComposerNSTextView {
        let window = try window(for: nil)
        guard let content = window.contentView, let composer = ViewFinder.first(ComposerNSTextView.self, in: content) else {
            throw ControlError.noComposer
        }
        return composer
    }

    private func chatListDocumentView() throws -> ChatListDocumentView {
        let window = try window(for: nil)
        guard let content = window.contentView, let list = ViewFinder.first(ChatListDocumentView.self, in: content) else {
            throw ControlError.notFound("chat list")
        }
        return list
    }

    /// Text-bearing views under `root`, top to bottom.
    private func textViews(in root: NSView) -> [NSView] {
        let views: [NSView] = ViewFinder.all(NSTextView.self, in: root) + ViewFinder.all(NSTextField.self, in: root)
        return views
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .filter { !($0 is NSTextView && ($0 as! NSTextView).isFieldEditor) }
            .sorted { a, b in
                let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
                if fa.maxY != fb.maxY { return fa.maxY > fb.maxY }
                return fa.minX < fb.minX
            }
    }

    private func chatListTextViews() throws -> [NSView] {
        textViews(in: try chatListDocumentView())
    }

    private func textViews(within entry: ControlEntry) throws -> [NSView] {
        let window = try window(for: entry)
        let height = contentHeight(of: window)
        return textViews(in: window.contentView!).filter { view in
            let frame = WindowGeometry.topLeftRect(fromAppKit: view.convert(view.bounds, to: nil), contentHeight: height)
            return entry.frame.insetBy(dx: -1, dy: -1).intersects(frame)
        }
    }

    private func textCandidates(for target: ControlTarget?) throws -> [NSView] {
        switch target {
        case .composer?: return [try composerTextView()]
        case .chatList?: return try chatListTextViews()
        case .window?: return textViews(in: try window(for: nil).contentView!)
        case .control?: return try textViews(within: registry.resolve(target!))
        case nil:
            let window = try window(for: nil)
            var ordered: [NSView] = []
            if let composer = try? composerTextView() { ordered.append(composer) }
            if let rows = try? chatListTextViews() { ordered.append(contentsOf: rows) }
            for view in textViews(in: window.contentView!) where !ordered.contains(where: { $0 === view }) {
                ordered.append(view)
            }
            return ordered
        }
    }

    private func frame(of target: ControlTarget) throws -> CGRect? {
        let window = try window(for: nil, target: target)
        let height = contentHeight(of: window)
        switch target {
        case .window: return nil
        case .composer:
            let composer = try composerTextView()
            let host = composer.enclosingScrollView?.superview ?? composer
            return WindowGeometry.topLeftRect(fromAppKit: host.convert(host.bounds, to: nil), contentHeight: height)
        case .chatList:
            let list = try chatListDocumentView()
            let host = list.enclosingScrollView ?? list
            return WindowGeometry.topLeftRect(fromAppKit: host.convert(host.bounds, to: nil), contentHeight: height)
        case .control:
            return try registry.resolve(target).frame
        }
    }

    private func rootView(for target: ControlTarget, in content: NSView) throws -> NSView {
        switch target {
        case .window: return content
        case .composer:
            let composer = try composerTextView()
            return composer.enclosingScrollView?.superview ?? composer
        case .chatList:
            let list = try chatListDocumentView()
            return list.enclosingScrollView ?? list
        case .control:
            let entry = try registry.resolve(target)
            return smallestView(containing: entry.frame, in: content, contentHeight: content.bounds.height) ?? content
        }
    }

    private func smallestView(containing frame: CGRect, in root: NSView, contentHeight: CGFloat) -> NSView? {
        var best: NSView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let viewFrame = WindowGeometry.topLeftRect(fromAppKit: view.convert(view.bounds, to: nil), contentHeight: contentHeight)
            guard viewFrame.insetBy(dx: -1, dy: -1).contains(frame) else { return }
            let area = viewFrame.width * viewFrame.height
            if area < bestArea, area > 0 {
                best = view
                bestArea = area
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best
    }
}
#endif
