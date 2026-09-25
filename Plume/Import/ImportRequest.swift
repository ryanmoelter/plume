import AppKit
import Observation

/// Asks a main window to show the cmux import sheet, from a window like
/// Settings that has no import action of its own.
@MainActor
@Observable
final class ImportRequest {
    static let shared = ImportRequest()

    private(set) var targetWindowNumber: Int?
    @ObservationIgnored private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    func register(_ window: NSWindow) {
        mainWindows.add(window)
    }

    /// Targets the frontmost main window. False when none is open, so the
    /// request never waits around for a window the user opens later.
    @discardableResult
    func request() -> Bool {
        guard let window = NSApp.orderedWindows.first(where: mainWindows.contains) else { return false }
        targetWindowNumber = window.windowNumber
        return true
    }

    /// Whether `window` is the target, clearing the request if so.
    func take(for window: NSWindow?) -> Bool {
        guard let window, targetWindowNumber == window.windowNumber else { return false }
        targetWindowNumber = nil
        return true
    }
}
