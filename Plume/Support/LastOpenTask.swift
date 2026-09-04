import Foundation

/// Remembers which task was selected, so a launch reopens where the user left
/// off rather than on the empty detail pane.
///
/// Kept out of `AppSettings`, which holds preferences the Settings window
/// offers — this is restored window state, and nobody sets it deliberately.
nonisolated enum LastOpenTask {
    private static let key = "lastOpenTaskID"

    static func load(from defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// A nil selection clears the stored ID, so deleting or archiving the last
    /// open task doesn't leave the next launch pointing at it.
    static func save(_ id: UUID?, to defaults: UserDefaults = .standard) {
        guard let id else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(id.uuidString, forKey: key)
    }
}
