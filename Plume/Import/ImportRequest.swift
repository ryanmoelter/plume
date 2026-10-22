import AppKit
import Observation

/// Asks a main window to show an import sheet, from a window like
/// Settings that has no import action of its own.
@MainActor
@Observable
final class ImportRequest {
    static let shared = ImportRequest()

    private(set) var targetWindowNumber: Int?
    private(set) var requestedSource: ImportSource?
    @ObservationIgnored private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    func register(_ window: NSWindow) {
        mainWindows.add(window)
    }

    /// Targets the frontmost main window. False when none is open, so the
    /// request never waits around for a window the user opens later.
    @discardableResult
    func request(_ source: ImportSource) -> Bool {
        guard let window = NSApp.orderedWindows.first(where: mainWindows.contains) else { return false }
        targetWindowNumber = window.windowNumber
        requestedSource = source
        return true
    }

    /// The requested source if `window` is the target, clearing the request.
    func take(for window: NSWindow?) -> ImportSource? {
        guard let window, targetWindowNumber == window.windowNumber, let source = requestedSource else { return nil }
        targetWindowNumber = nil
        requestedSource = nil
        return source
    }
}
