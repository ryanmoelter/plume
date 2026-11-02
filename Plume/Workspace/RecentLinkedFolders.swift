import Foundation

/// The folders conversations have reached with `--add-dir`, most recent
/// first, so the add-folder menu can offer them again.
///
/// Kept apart from `RecentFolders`: a folder linked to a conversation is not
/// a project a task runs in, and must never become a new task's default.
nonisolated enum RecentLinkedFolders {
    private static let key = "recentLinkedFolders"
    static let limit = 10

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// `paths` go to the front in the order given.
    static func remember(_ paths: [String], in defaults: UserDefaults = .standard) {
        let fresh = AddFolderCandidates.deduplicated(paths).map(AddFolderCandidates.key)
        guard !fresh.isEmpty else { return }
        let keys = Set(fresh)
        let kept = load(from: defaults).filter { !keys.contains(AddFolderCandidates.key($0)) }
        defaults.set(Array((fresh + kept).prefix(limit)), forKey: key)
    }
}

/// What the add-folder menu offers: recently linked folders, then recent
/// projects, leaving out whatever the conversation already reaches.
nonisolated struct AddFolderCandidates: Equatable {
    var folders: [String]
    var projects: [String]

    var isEmpty: Bool { folders.isEmpty && projects.isEmpty }

    init(folders: [String], projects: [String]) {
        self.folders = folders
        self.projects = projects
    }

    /// Paths compare lexically: this runs while a menu draws, so it reads no
    /// file system to resolve symlinks.
    init(recentFolders: [String], recentProjects: [String], linked: [String], workingDirectory: String?) {
        var taken = Set((linked + [workingDirectory].compactMap { $0 }).map(Self.key))
        folders = Self.deduplicated(recentFolders).filter { taken.insert(Self.key($0)).inserted }
        projects = Self.deduplicated(recentProjects).filter { taken.insert(Self.key($0)).inserted }
    }

    static func key(_ path: String) -> String {
        AdditionalDirectories.normalized(path) ?? path
    }

    static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert(key($0)).inserted }
    }
}
