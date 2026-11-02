import Foundation

/// A working directory split into the checkout it sits in and the folder
/// beneath that checkout, so the project reads as one choice and the
/// subfolder as another.
nonisolated struct ProjectSubfolder: Equatable, Sendable {
    let projectRoot: String
    let checkoutRoot: String
    /// Relative to `checkoutRoot`. Nil when the path is the checkout itself.
    let subfolder: String?

    /// What the subfolder dropdown reads with no subfolder chosen.
    static let rootTitle = "Project root"

    /// Nil when `path` is not inside the checkout `facts` describes, which
    /// includes any folder git does not track.
    static func split(path: String, facts: CheckoutFacts?) -> ProjectSubfolder? {
        guard let facts, let subfolder = relativePath(of: path, in: facts.checkoutRoot) else { return nil }
        return ProjectSubfolder(
            projectRoot: facts.projectRoot,
            checkoutRoot: facts.checkoutRoot,
            subfolder: subfolder.isEmpty ? nil : subfolder
        )
    }

    /// `path` relative to `checkoutRoot`: empty for the checkout itself, nil
    /// for a path outside it.
    static func relativePath(of path: String, in checkoutRoot: String) -> String? {
        let checkout = standardized(checkoutRoot)
        let target = standardized(path)
        if target == checkout { return "" }
        let prefix = checkout.hasSuffix("/") ? checkout : checkout + "/"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// The directory a task runs in for `subfolder` beneath `checkoutRoot`.
    static func directory(checkoutRoot: String, subfolder: String?) -> String {
        guard let subfolder, !subfolder.isEmpty else { return checkoutRoot }
        return (checkoutRoot as NSString).appendingPathComponent(subfolder)
    }

    /// `directory(checkoutRoot:subfolder:)`, or the checkout itself when it
    /// has no such folder — another worktree need not have every folder the
    /// subfolder was chosen from.
    static func existingDirectory(
        checkoutRoot: String,
        subfolder: String?,
        isDirectory: (String) -> Bool = Self.isDirectory
    ) -> String {
        let candidate = directory(checkoutRoot: checkoutRoot, subfolder: subfolder)
        return candidate == checkoutRoot || isDirectory(candidate) ? candidate : checkoutRoot
    }

    /// The folders directly inside `directory`, as the subfolder dropdown
    /// lists them. Reads the disk, so call it off the main actor.
    static func childFolders(of directory: String) -> [String] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
