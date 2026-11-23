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
            id: entry.id, index: match.index, label: entry.label, value: entry.currentValue, isEnabled: entry.isEnabled,
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
            let composer = try composerTextView()
            let selected = composer.selectedRange()
            return TextResult(
                text: composer.string, rows: nil,
                selection: TextRange(location: selected.location, length: selected.length),
                checkboxes: try checkboxes(in: composer)
            )
        case .chatList:
            let rows = try textItems(in: try chatListDocumentView()).map(\.text).filter { !$0.isEmpty }
            return TextResult(text: rows.joined(separator: "\n"), rows: rows.enumerated().map { TextRow(index: $0.offset, text: $0.element) })
        case .window:
            let window = try window(for: nil)
            let rows = textItems(in: window.contentView!).map(\.text).filter { !$0.isEmpty }
            return TextResult(text: rows.joined(separator: "\n"), rows: rows.enumerated().map { TextRow(index: $0.offset, text: $0.element) })
        case .control:
            let entry = try registry.resolve(target)
            if let value = entry.currentValue { return TextResult(text: value, rows: nil) }
            let rows = try textItems(within: entry).map(\.text).filter { !$0.isEmpty }
            if rows.isEmpty, let label = entry.label { return TextResult(text: label, rows: nil) }
            return TextResult(text: rows.joined(separator: "\n"), rows: nil)
        }
    }

    private func checkboxes(in composer: ComposerNSTextView) throws -> [CheckboxDescription] {
        let window = try window(for: nil)
        let height = contentHeight(of: window)
        let text = composer.string as NSString
        return composer.visibleCheckboxes.map { box in
            let prefix = text.substring(to: box.box.location)
            let rect = WindowGeometry.topLeftRect(fromAppKit: composer.convert(box.rect, to: nil), contentHeight: height)
            return CheckboxDescription(line: prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }, isChecked: box.isChecked, rect: Rect(rect))
        }
    }

    // MARK: Clicks

    func clickSpan(_ params: ClickSpanParams) async throws -> ClickResult {
        let candidates = try textCandidates(for: params.target)
        guard let hit = TextSpanLocator.locate(params.matching, occurrence: params.occurrence, in: candidates, revealing: true) else {
            throw ControlError.spanNotFound(params.matching)
        }
        guard let window = hit.window else { throw ControlError.noWindow }
        let rect = WindowGeometry.topLeftRect(fromAppKit: hit.rectInWindow, contentHeight: contentHeight(of: window))
        guard hit.isVisible else {
            throw ControlError.unsupported("\"\(params.matching)\" is at \(Rect(rect)), outside its view's visible area")
        }
        let point = CGPoint(x: hit.rectInWindow.midX, y: hit.rectInWindow.midY)
        let view = SyntheticClick.hitView(at: point, in: window)
        await SyntheticClick.perform(at: point, in: window)
        return ClickResult(rect: Rect(rect), windowNumber: window.windowNumber, view: view.map { String(describing: type(of: $0)) })
    }

    func click(_ params: ClickParams) async throws -> ClickResult {
        let window = try window(for: params.windowNumber)
        let point = WindowGeometry.appKitPoint(fromTopLeft: CGPoint(x: params.x, y: params.y), contentHeight: contentHeight(of: window))
        let view = SyntheticClick.hitView(at: point, in: window)
        await SyntheticClick.perform(at: point, in: window, clickCount: params.clickCount)
        return ClickResult(
            rect: Rect(CGRect(x: params.x, y: params.y, width: 0, height: 0)), windowNumber: window.windowNumber,
            view: view.map { String(describing: type(of: $0)) }
        )
    }

    func pointerDrag(_ params: PointerDragParams) async throws -> ClickResult {
        let window = try window(for: params.windowNumber)
        let height = contentHeight(of: window)
        let start = WindowGeometry.appKitPoint(fromTopLeft: CGPoint(x: params.fromX, y: params.fromY), contentHeight: height)
        let end = WindowGeometry.appKitPoint(fromTopLeft: CGPoint(x: params.toX, y: params.toY), contentHeight: height)
        let view = SyntheticClick.hitView(at: start, in: window)
        await SyntheticClick.drag(from: start, to: end, in: window, clickCount: params.clickCount, steps: params.steps)
        return ClickResult(
            rect: Rect(CGRect(x: params.toX, y: params.toY, width: 0, height: 0)), windowNumber: window.windowNumber,
            view: view.map { String(describing: type(of: $0)) }
        )
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
        return HoverResult(
            rect: Rect(rect), windowNumber: window.windowNumber, regions: HoverRegistry.shared.hoveredCount,
            chatCursor: chatCursor(at: point, in: window)
        )
    }

    /// Runs the chat list's own pointer update, which the synthetic pointer
    /// never triggers, and names the cursor it left set.
    private func chatCursor(at point: NSPoint, in window: NSWindow) -> String? {
        guard let content = window.contentView,
              let list = ViewFinder.all(ChatListDocumentView.self, in: content).first(where: {
                  $0.visibleRect.contains($0.convert(point, from: nil))
              }),
              let controller = list.controller else { return nil }
        controller.updatePointer(at: point)
        return switch NSCursor.current {
        case .iBeam: "iBeam"
        case .pointingHand: "pointingHand"
        case .arrow: "arrow"
        default: "other"
        }
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
        if let gap = drag.tabStripGap { out.append("tabStrip pane \(gap.pane) gap \(gap.gap)") }
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
        let item = Self.menuItem(matching: shortcut)
        let code = try await SyntheticKey.perform(shortcut, in: window)
        return KeyResult(
            chord: Self.chordName(shortcut, typed: params.key), keyCode: Int(code), windowNumber: window.windowNumber,
            handledBy: item.map(Self.path(of:)), handledByEnabled: item?.isEnabled,
            firstResponder: window.firstResponder.map { String(describing: type(of: $0)) }
        )
    }

    func windowSize(_ params: WindowSizeParams) throws -> WindowSizeResult {
        let window = try window(for: params.windowNumber)
        switch (params.width, params.height) {
        case let (width?, height?):
            window.setContentSize(NSSize(width: width, height: height))
        case (nil, nil):
            break
        default:
            throw ControlError.badParams("windowSize needs both width and height, or neither")
        }
        let size = window.contentView?.bounds.size ?? window.contentRect(forFrameRect: window.frame).size
        return WindowSizeResult(windowNumber: window.windowNumber, width: size.width, height: size.height)
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

    static func shortcut(from params: KeyParams) throws -> MenuShortcut {
        guard let key = SyntheticKey.character(named: params.key) ?? (params.key.count == 1 ? params.key.first : nil) else {
            let names = SyntheticKey.named.map(\.name).joined(separator: ", ")
            throw ControlError.badParams("key must be a single character or one of \(names), got \"\(params.key)\"")
        }
        var modifiers: EventModifiers = []
        if key.isUppercase, key.isLetter { modifiers.insert(.shift) }
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

    /// A named key reads by its name, since its character is a private-use
    /// code point.
    private static func chordName(_ shortcut: MenuShortcut, typed: String) -> String {
        guard SyntheticKey.character(named: typed) != nil else { return shortcut.displayName }
        return String(MenuShortcut("x", modifiers: shortcut.modifiers).displayName.dropLast()) + typed.lowercased()
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

    // MARK: Window

    func resize(_ params: ResizeParams) async throws -> ResizeResult {
        let window = try window(for: params.windowNumber)
        let target = CGSize(width: params.width, height: params.height)
        guard target.width > 0, target.height > 0 else { throw ControlError.badParams("width and height must be positive") }
        var sizes: [Size] = []
        func setContentSize(_ size: CGSize) {
            window.setContentSize(size)
            sizes.append(Size(contentSize(of: window)))
        }
        if params.live {
            try await WindowLiveResize.run(window) {
                let start = contentSize(of: window)
                for step in 1...params.steps {
                    let fraction = CGFloat(step) / CGFloat(params.steps)
                    setContentSize(CGSize(
                        width: (start.width + (target.width - start.width) * fraction).rounded(),
                        height: (start.height + (target.height - start.height) * fraction).rounded()
                    ))
                    try? await Task.sleep(for: .seconds(params.stepDelay))
                }
            }
        } else {
            setContentSize(target)
        }
        await Task.yield()
        let final = contentSize(of: window)
        return ResizeResult(windowNumber: window.windowNumber, width: final.width, height: final.height, sizes: sizes, live: params.live)
    }

    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentView?.bounds.size ?? window.contentRect(forFrameRect: window.frame).size
    }

    // MARK: Screenshot

    func screenshot(_ params: ScreenshotParams) throws -> ScreenshotResult {
        let window = try window(for: params.windowNumber, target: params.target)
        let (image, scale, _) = try captureContent(of: window, target: params.target)
        let out = NSBitmapImageRep(cgImage: image)
        guard let png = out.representation(using: .png, properties: [:]) else { throw ControlError.io("could not encode PNG") }
        let path = params.path ?? defaultScreenshotPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: path))
        return ScreenshotResult(path: path, width: image.width, height: image.height, scale: scale)
    }

    /// The content view's pixels with the overlay pointer on top, cropped to
    /// `target` when given; refuses a blank capture.
    private func captureContent(of window: NSWindow, target: ControlTarget?) throws -> (image: CGImage, scale: Double, request: RecordingFrameRequest) {
        guard let captured = WindowCapture.image(of: window) else {
            throw ControlError.io("the window server has no image of this window; a hidden app (open -j) cannot be captured, relaunch without -j (\(WindowCapture.displayState))")
        }
        let scale = Double(captured.width) / Double(window.frame.width)
        guard var request = Self.frameRequest(for: window, scale: scale) else { throw ControlError.noWindow }
        guard var image = captured.cropping(to: request.contentRect) else { throw ControlError.io("could not crop to the content view") }
        if WindowCapture.isUniform(image) {
            throw ControlError.io("captured a blank window (\(WindowCapture.displayState))")
        }
        if let overlayID = request.overlayID, let cursor = WindowCapture.image(windowID: overlayID) {
            image = WindowCapture.composite(cursor, over: image) ?? image
        }
        if let target, let crop = try cropRect(for: target, scale: scale) {
            guard let cropped = image.cropping(to: crop) else { throw ControlError.io("could not crop to \(target)") }
            image = cropped
            request.targetRect = crop
        }
        return (image, scale, request)
    }

    private static func frameRequest(for window: NSWindow, scale: Double) -> RecordingFrameRequest? {
        guard let content = window.contentView else { return nil }
        let contentInWindow = content.convert(content.bounds, to: nil)
        let contentRect = CGRect(
            x: contentInWindow.minX * scale, y: (window.frame.height - contentInWindow.maxY) * scale,
            width: contentInWindow.width * scale, height: contentInWindow.height * scale
        ).integral
        let overlay = ControlOverlay.existing(for: window).map { UInt32($0.panel.windowNumber) }
        return RecordingFrameRequest(windowID: UInt32(window.windowNumber), overlayID: overlay, contentRect: contentRect, targetRect: nil)
    }

    // MARK: Recording

    /// The target's crop is fixed at the start; the window's own frame and
    /// the overlay are re-read every frame.
    func recordStart(_ params: RecordStartParams) throws -> RecordStartResult {
        let window = try window(for: params.windowNumber, target: params.target)
        let (first, scale, request) = try captureContent(of: window, target: params.target)
        let url = URL(fileURLWithPath: params.path ?? defaultCapturePath(folder: "recordings", extension: "mp4"))
        let targetRect = request.targetRect
        let size = try WindowRecorder.shared.start(
            url: url, firstFrame: first, fps: params.fps, maxSeconds: params.maxSeconds
        ) { [weak window] in
            guard let window else { return nil }
            var next = Self.frameRequest(for: window, scale: window.backingScaleFactor)
            next?.targetRect = targetRect
            return next
        }
        return RecordStartResult(
            path: url.path(percentEncoded: false), width: size.width, height: size.height, scale: scale,
            fps: params.fps, maxSeconds: params.maxSeconds
        )
    }

    func recordStop() async throws -> RecordStopResult {
        try await WindowRecorder.shared.stop()
    }

    private func cropRect(for target: ControlTarget, scale: Double) throws -> CGRect? {
        guard let frame = try frame(of: target) else { return nil }
        return CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
    }

    /// Fractional seconds, so two shots in one second do not overwrite each other.
    private func defaultScreenshotPath() -> String {
        defaultCapturePath(folder: "screenshots", extension: "png")
    }

    private func defaultCapturePath(folder: String, extension ext: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return AppPaths.controlDirectory.appending(path: "\(folder)/\(stamp).\(ext)").path(percentEncoded: false)
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
        guard let content = window.contentView,
              let composer = inFocusedPane(ViewFinder.all(ComposerNSTextView.self, in: content), of: window)
        else { throw ControlError.noComposer }
        return composer
    }

    private func chatListDocumentView() throws -> ChatListDocumentView {
        let window = try window(for: nil)
        guard let content = window.contentView,
              let list = inFocusedPane(ViewFinder.all(ChatListDocumentView.self, in: content), of: window)
        else { throw ControlError.notFound("chat list") }
        return list
    }

    /// A split shows two chats, so the composer and chat list surfaces
    /// resolve to the focused pane's — or to nothing, when the focused pane
    /// holds no such view.
    private func inFocusedPane<View: NSView>(_ candidates: [View], of window: NSWindow) -> View? {
        let pane = registry.entries(id: AccessibilityID.tabPane)
            .first(where: { $0.entry.value == "focused" && $0.entry.window === window })?.entry
        let height = contentHeight(of: window)
        let placed = candidates.map { view in
            (view, WindowGeometry.topLeftRect(fromAppKit: view.convert(view.shownRect, to: nil), contentHeight: height))
        }
        return Self.candidate(in: placed, focusedPaneFrame: pane?.frame)
    }

    /// With no pane registered, the first candidate in tree order.
    static func candidate<View>(in candidates: [(View, CGRect)], focusedPaneFrame: CGRect?) -> View? {
        guard let focusedPaneFrame else { return candidates.first?.0 }
        return candidates.first { focusedPaneFrame.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }?.0
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

    /// `textViews(in:)` plus the chat pieces' own `Text`s, top to bottom.
    private func textItems(in root: NSView) -> [TextSpanLocator.Item] {
        var items = textViews(in: root).map(TextSpanLocator.Item.view)
        for list in ViewFinder.all(ChatListDocumentView.self, in: root) {
            guard let controller = list.controller else { continue }
            items += controller.selectableTextFrames().map { TextSpanLocator.Item.chat($0, controller) }
        }
        return items.sorted { a, b in
            let fa = a.rectInWindow, fb = b.rectInWindow
            if fa.maxY != fb.maxY { return fa.maxY > fb.maxY }
            return fa.minX < fb.minX
        }
    }

    private func textItems(within entry: ControlEntry) throws -> [TextSpanLocator.Item] {
        let window = try window(for: entry)
        let height = contentHeight(of: window)
        return textItems(in: window.contentView!).filter { item in
            let frame = WindowGeometry.topLeftRect(fromAppKit: item.rectInWindow, contentHeight: height)
            return entry.frame.insetBy(dx: -1, dy: -1).intersects(frame)
        }
    }

    private func textCandidates(for target: ControlTarget?) throws -> [TextSpanLocator.Item] {
        switch target {
        case .composer?: return [.view(try composerTextView())]
        case .chatList?: return textItems(in: try chatListDocumentView())
        case .window?: return textItems(in: try window(for: nil).contentView!)
        case .control?: return try textItems(within: registry.resolve(target!))
        case nil:
            let window = try window(for: nil)
            var ordered: [TextSpanLocator.Item] = []
            if let composer = try? composerTextView() { ordered.append(.view(composer)) }
            if let list = try? chatListDocumentView() { ordered.append(contentsOf: textItems(in: list)) }
            for item in textItems(in: window.contentView!) where !ordered.contains(where: { $0.isSame(as: item) }) {
                ordered.append(item)
            }
            return ordered
        }
    }

    // MARK: Selection

    func selection() throws -> SelectionResult {
        try selectionResult(of: try chatListController())
    }

    func injectUsage(_ params: InjectUsageParams) async throws -> InjectUsageResult {
        let result = try UsageInjection.apply(
            params, store: .shared, settings: .shared, poller: .shared
        )
        await UsageInjection.settle(NSApp.windows)
        return result
    }

    // MARK: Scrolling

    func scrollTo(_ params: ScrollToParams) throws {
        try params.validate()
        let window = try window(for: params.windowNumber, target: params.target)
        guard let content = window.contentView else { throw ControlError.noWindow }
        let scrollable = ViewFinder.all(NSScrollView.self, in: content).filter { scrollView in
            guard !scrollView.isHiddenOrHasHiddenAncestor, let document = scrollView.documentView else { return false }
            return document.frame.height > scrollView.contentView.bounds.height
        }
        let height = contentHeight(of: window)
        let topLeftFrame = { (view: NSView) in
            WindowGeometry.topLeftRect(fromAppKit: view.convert(view.bounds, to: nil), contentHeight: height)
        }

        if let edge = params.edge {
            guard edge == "top" || edge == "bottom" else { throw ControlError.badParams("edge is top or bottom") }
            guard let scrollView = scrollable.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { throw ControlError.notFound("a scrollable view") }
            scroll(scrollView, toBottom: edge == "bottom")
            return
        }

        let entry = try registry.resolve(params.target!)
        // The innermost scroll view whose column holds the control.
        let containing = scrollable
            .filter { let frame = topLeftFrame($0); return frame.minX <= entry.frame.midX && entry.frame.midX <= frame.maxX }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let scrollView = containing else { throw ControlError.notFound("a scroll view around \(params.target!)") }
        let visible = topLeftFrame(scrollView.contentView)
        let margin: CGFloat = 12
        let delta: CGFloat
        if entry.frame.minY < visible.minY {
            delta = entry.frame.minY - visible.minY - margin
        } else if entry.frame.maxY > visible.maxY {
            delta = min(entry.frame.maxY - visible.maxY + margin, entry.frame.minY - visible.minY - margin)
        } else {
            return
        }
        scroll(scrollView, by: delta)
    }

    /// `delta` is in screen direction: positive moves the content up, the
    /// way scrolling down does.
    private func scroll(_ scrollView: NSScrollView, by delta: CGFloat) {
        let clip = scrollView.contentView
        let flipped = scrollView.documentView?.isFlipped ?? true
        var origin = clip.bounds.origin
        origin.y += flipped ? delta : -delta
        setOrigin(origin, of: scrollView)
    }

    private func scroll(_ scrollView: NSScrollView, toBottom: Bool) {
        let flipped = scrollView.documentView?.isFlipped ?? true
        let maxY = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        var origin = scrollView.contentView.bounds.origin
        origin.y = toBottom == flipped ? maxY : 0
        setOrigin(origin, of: scrollView)
    }

    private func setOrigin(_ origin: CGPoint, of scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let maxY = max((scrollView.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
        clip.scroll(to: CGPoint(x: origin.x, y: min(max(origin.y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    func selectText(_ params: SelectTextParams) throws -> SelectionResult {
        let controller = try chatListController()
        let from = params.matching ?? params.from
        guard let from else { throw ControlError.badParams("selectText needs matching, or from and to") }
        if params.matching != nil, params.to != nil { throw ControlError.badParams("selectText takes matching or from/to, not both") }
        guard controller.selectText(from: from, to: params.to, occurrence: params.occurrence) else {
            throw ControlError.spanNotFound(params.to.map { "\(from)…\($0)" } ?? from)
        }
        return try selectionResult(of: controller)
    }

    func chatListController() throws -> ChatListController {
        guard let controller = try chatListDocumentView().controller else { throw ControlError.notFound("chat list") }
        return controller
    }

    private func selectionResult(of controller: ChatListController) throws -> SelectionResult {
        guard let current = controller.selection.selection else {
            return SelectionResult(markdown: "", plainText: "", anchor: nil, focus: nil)
        }
        let pieces = controller.inputs.pieces
        return SelectionResult(
            markdown: ChatSelectionSerializer.markdown(of: pieces, selection: current),
            plainText: ChatSelectionSerializer.plainText(of: pieces, selection: current),
            anchor: SelectionPoint(pieceID: current.anchor.pieceID, offset: current.anchor.offset),
            focus: SelectionPoint(pieceID: current.focus.pieceID, offset: current.focus.offset)
        )
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
