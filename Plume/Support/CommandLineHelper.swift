import Foundation

/// Puts the bundled `plume-notify` script on the user's PATH, as a symlink
/// into `~/.local/bin`.
///
/// A symlink rather than a copy, so the helper tracks whatever Plume is
/// installed instead of going stale after an upgrade. The link points into
/// the app bundle, which means moving or deleting Plume breaks it — `state`
/// reports that as `.brokenLink` so the UI can offer to relink.
enum CommandLineHelper {
    static let commandName = "plume-notify"

    /// Not `/usr/local/bin`: writing there needs admin rights, and this
    /// user's shell profile already has `~/.local/bin`.
    static var installDirectory: URL {
        URL.homeDirectory.appending(path: ".local/bin")
    }

    static var installedURL: URL {
        installDirectory.appending(path: commandName)
    }

    /// The script inside the app bundle. Nil in a host with no bundled
    /// resources, such as the test host.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: commandName, withExtension: nil)
    }

    enum State: Equatable {
        case installed
        case notInstalled
        /// Something else already owns the name — a real file, or a symlink
        /// to another tool. Overwriting it is the user's call, not ours.
        case occupiedByOther(URL?)
        /// Installed by Plume, but the bundle it pointed at is gone.
        case brokenLink
    }

    static func state(
        installedURL: URL = installedURL,
        bundledURL: URL? = bundledURL
    ) -> State {
        let manager = FileManager.default
        let destination = try? manager.destinationOfSymbolicLink(atPath: installedURL.path)

        guard let destination else {
            // `fileExists` follows symlinks, so reaching here with a true
            // answer means a regular file, not a link.
            return manager.fileExists(atPath: installedURL.path)
                ? .occupiedByOther(nil)
                : .notInstalled
        }

        let resolved = URL(fileURLWithPath: destination, relativeTo: installedURL)
            .standardizedFileURL
        if let bundledURL, resolved == bundledURL.standardizedFileURL {
            return .installed
        }
        if manager.fileExists(atPath: resolved.path) {
            return .occupiedByOther(resolved)
        }
        // A dangling link into some app bundle is ours in every case that
        // matters; a dangling link to anything else is equally safe to replace.
        return .brokenLink
    }

    enum InstallError: LocalizedError {
        case notBundled
        case occupied(URL?)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                "This build of \(AppIdentity.displayName) does not carry the \(commandName) helper."
            case .occupied(let destination):
                if let destination {
                    "\(installedURL.path) already points at \(destination.path)."
                } else {
                    "\(installedURL.path) already exists."
                }
            }
        }
    }

    /// Creates the symlink, replacing one Plume placed itself.
    ///
    /// Throws rather than overwriting when something else owns the name.
    static func install() throws {
        guard let bundledURL else { throw InstallError.notBundled }

        switch state() {
        case .installed:
            return
        case .occupiedByOther(let destination):
            throw InstallError.occupied(destination)
        case .brokenLink:
            try FileManager.default.removeItem(at: installedURL)
        case .notInstalled:
            break
        }

        try FileManager.default.createDirectory(
            at: installDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: installedURL, withDestinationURL: bundledURL)
    }

    static func uninstall() throws {
        guard case .installed = state() else { return }
        try FileManager.default.removeItem(at: installedURL)
    }
}
