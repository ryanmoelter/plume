#if DEBUG
import AppKit

/// Renders a window's view tree as text an agent can read instead of a
/// screenshot. Views that carry nothing worth reading are collapsed into
/// their children; registered `plumeID` controls, which have no view of
/// their own, are attached to the smallest view enclosing them.
@MainActor
enum HierarchyDumper {
    static func dump(
        root: NSView,
        controls: [(index: Int, entry: ControlEntry)],
        contentHeight: CGFloat,
        textLimit: Int
    ) -> HierarchyNode {
        let owners = assignOwners(of: controls, under: root, contentHeight: contentHeight)
        var node = build(root, controls: controls, owners: owners, contentHeight: contentHeight, textLimit: textLimit)
        node = prune(node) ?? HierarchyNode(kind: node.kind, frame: node.frame)
        return node
    }

    static func render(_ node: HierarchyNode) -> String {
        var lines: [String] = []
        render(node, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    // MARK: Build

    /// Each control goes to the smallest visible view whose frame contains
    /// it. Depth alone would hand a composer control to a full-height
    /// terminal view that happens to sit behind it.
    private static func assignOwners(
        of controls: [(index: Int, entry: ControlEntry)],
        under root: NSView,
        contentHeight: CGFloat
    ) -> [UUID: ObjectIdentifier] {
        var views: [(view: NSView, frame: CGRect)] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            views.append((view, viewFrame(view, contentHeight)))
            view.subviews.forEach(visit)
        }
        visit(root)
        var owners: [UUID: ObjectIdentifier] = [:]
        for (_, entry) in controls {
            var best: (view: NSView, area: CGFloat)?
            for (view, frame) in views where frame.insetBy(dx: -2, dy: -2).contains(entry.frame) {
                let area = frame.width * frame.height
                if best == nil || area < best!.area { best = (view, area) }
            }
            if let best { owners[entry.token] = ObjectIdentifier(best.view) }
        }
        return owners
    }

    private static func build(
        _ view: NSView,
        controls: [(index: Int, entry: ControlEntry)],
        owners: [UUID: ObjectIdentifier],
        contentHeight: CGFloat,
        textLimit: Int
    ) -> HierarchyNode {
        var node = HierarchyNode(kind: String(describing: type(of: view)), frame: Rect(viewFrame(view, contentHeight)))
        node.text = clip(text(of: view), to: textLimit)
        if let control = view as? NSControl {
            node.isEnabled = control.isEnabled
        }
        for child in view.subviews where !child.isHidden {
            node.children.append(build(child, controls: controls, owners: owners, contentHeight: contentHeight, textLimit: textLimit))
        }
        let me = ObjectIdentifier(view)
        for (index, entry) in controls where owners[entry.token] == me {
            node.children.append(HierarchyNode(
                kind: "control", plumeID: entry.id, index: index, label: entry.label, value: entry.value,
                text: nil, isEnabled: entry.isEnabled, frame: Rect(entry.frame)
            ))
        }
        node.children.sort(by: visualOrder)
        return node
    }

    private static func viewFrame(_ view: NSView, _ contentHeight: CGFloat) -> CGRect {
        WindowGeometry.topLeftRect(fromAppKit: view.convert(view.bounds, to: nil), contentHeight: contentHeight)
    }

    private static func text(of view: NSView) -> String? {
        switch view {
        case let textView as NSTextView: textView.string.isEmpty ? nil : textView.string
        case let button as NSButton: button.title.isEmpty ? nil : button.title
        case let field as NSTextField: field.stringValue.isEmpty ? nil : field.stringValue
        default: nil
        }
    }

    private static func clip(_ text: String?, to limit: Int) -> String? {
        guard var text else { return nil }
        text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: Prune

    private static func prune(_ node: HierarchyNode) -> HierarchyNode? {
        var kept = node
        kept.children = node.children.flatMap { child -> [HierarchyNode] in
            guard let pruned = prune(child) else { return [] }
            return isInteresting(pruned) ? [pruned] : pruned.children
        }
        kept.children.sort(by: visualOrder)
        if !isInteresting(kept) && kept.children.isEmpty { return nil }
        return kept
    }

    private static let boundaryKinds: Set<String> = ["NSScrollView", "ChatListDocumentView", "ScrollableComposerTextView"]

    private static func isInteresting(_ node: HierarchyNode) -> Bool {
        if node.kind == "control" || node.text != nil || node.isEnabled != nil { return true }
        if boundaryKinds.contains(node.kind) || node.kind.hasPrefix("NSHostingView") { return true }
        if node.kind.contains("Ghostty") || node.kind.contains("Terminal") { return true }
        return false
    }

    private static func visualOrder(_ a: HierarchyNode, _ b: HierarchyNode) -> Bool {
        if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
        return a.frame.x < b.frame.x
    }

    // MARK: Render

    private static func render(_ node: HierarchyNode, depth: Int, into lines: inout [String]) {
        var parts: [String] = [String(repeating: "  ", count: depth) + node.kind]
        if let id = node.plumeID { parts.append(id + (node.index.map { "#\($0)" } ?? "")) }
        if let label = node.label { parts.append("label=\(quote(label))") }
        if let value = node.value { parts.append("value=\(quote(value))") }
        if let text = node.text { parts.append(quote(text)) }
        parts.append(format(node.frame))
        if node.isEnabled == false { parts.append("disabled") }
        lines.append(parts.joined(separator: " "))
        for child in node.children { render(child, depth: depth + 1, into: &lines) }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func format(_ rect: Rect) -> String {
        "(\(Int(rect.x.rounded())),\(Int(rect.y.rounded())) \(Int(rect.width.rounded()))×\(Int(rect.height.rounded())))"
    }
}
#endif
