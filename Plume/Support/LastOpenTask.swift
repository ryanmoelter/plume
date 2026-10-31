import Foundation

/// Remembers what the sidebar had selected, so a launch reopens where the
/// user left off.
///
/// Kept out of `AppSettings`, which holds preferences the Settings window
/// offers — this is restored window state, and nobody sets it deliberately.
nonisolated enum LastOpenTask {
    private static let key = "lastOpenTaskID"
    private static let homeValue = "home"
    private static let lastTaskKey = "lastSelectedTaskID"

    static func load(from defaults: UserDefaults = .standard) -> SidebarSelection? {
        guard let stored = defaults.string(forKey: key) else { return nil }
        if stored == homeValue { return .home }
        return UUID(uuidString: stored).map(SidebarSelection.task)
    }

    /// A nil selection clears the stored value, so deleting or archiving the
    /// last open task doesn't leave the next launch pointing at it.
    static func save(_ selection: SidebarSelection?, to defaults: UserDefaults = .standard) {
        switch selection {
        case nil: defaults.removeObject(forKey: key)
        case .home: defaults.set(homeValue, forKey: key)
        case .task(let id):
            defaults.set(id.uuidString, forKey: key)
            defaults.set(id.uuidString, forKey: lastTaskKey)
        }
    }

    /// The last task selected, which choosing Home leaves in place. Home's
    /// composer starts on its group and project.
    static func lastTask(from defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: lastTaskKey).flatMap(UUID.init(uuidString:))
    }
}
