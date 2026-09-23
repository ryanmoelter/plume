#if DEBUG
import AppKit

/// Depth-first searches over a window's AppKit view tree, for the control
/// server and the debug harnesses that reach into hosted SwiftUI.
@MainActor
enum ViewFinder {
    static func first<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let found = first(type, in: sub) { return found }
        }
        return nil
    }

    static func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var out: [T] = []
        collect(root, into: &out)
        return out
    }

    private static func collect<T: NSView>(_ view: NSView, into out: inout [T]) {
        if let match = view as? T { out.append(match) }
        for sub in view.subviews { collect(sub, into: &out) }
    }

    /// The `NSTextField` SwiftUI backs `.textSelection(.enabled)` with. It is
    /// a private class, so it is matched by name.
    static func selectionTextFields(in root: NSView) -> [NSTextField] {
        all(NSTextField.self, in: root).filter { String(describing: type(of: $0)).contains("SelectionTextField") }
    }
}
#endif
