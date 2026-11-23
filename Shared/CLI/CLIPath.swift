import Foundation

nonisolated enum CLIPath {
    /// Git answers with symlinks resolved, so `/var/…` has to match `/private/var/…`.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// An argument as an absolute path: `~` expanded and relative to `directory`, symlinks kept.
    static func absolute(_ path: String, from directory: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }
}
