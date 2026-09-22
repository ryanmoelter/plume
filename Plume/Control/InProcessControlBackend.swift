#if DEBUG
import AppKit

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

    // MARK: Screenshot

    func screenshot(_ params: ScreenshotParams) throws -> ScreenshotResult {
        let window = try window(for: params.windowNumber, target: params.target)
        guard let content = window.contentView else { throw ControlError.noWindow }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw ControlError.io("could not allocate a bitmap for the window")
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / Double(content.bounds.width)
        var image = rep.cgImage
        if let target = params.target, let crop = try cropRect(for: target, scale: scale) {
            image = image?.cropping(to: crop)
        }
        guard let image else { throw ControlError.io("could not render the window") }
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

    private func defaultScreenshotPath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            throw ControlError.noWindow
        }
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
