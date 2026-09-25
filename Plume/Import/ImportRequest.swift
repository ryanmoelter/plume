import Observation

/// Asks a main window to show the cmux import sheet, from a window like
/// Settings that has no import action of its own. The first window to see
/// `isPending` takes it, so only one sheet opens.
@MainActor
@Observable
final class ImportRequest {
    static let shared = ImportRequest()

    var isPending = false

    private init() {}
}
