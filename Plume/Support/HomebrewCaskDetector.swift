import Foundation

/// Whether this app bundle was installed by Homebrew, detected by the
/// Caskroom directory it leaves behind. The cask links the `plume` tool
/// itself, so Plume must not link it a second time.
enum HomebrewCaskDetector {
    static let defaultPrefixes: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew"),
        URL(fileURLWithPath: "/usr/local"),
    ]

    static let isInstalledByHomebrew = isCaskInstall()

    static func isCaskInstall(prefixes: [URL] = defaultPrefixes, fileManager: FileManager = .default) -> Bool {
        prefixes.contains { prefix in
            var isDirectory: ObjCBool = false
            let path = prefix.appendingPathComponent("Caskroom/plume").path
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
