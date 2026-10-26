import Foundation
import os

/// Puts the bundled `plume` tool on the user's PATH, as symlinks into
/// `~/.local/bin`: `plume` itself, and `plume-notify`, the name the tool had
/// when it was a script, which it still answers to.
///
/// Symlinks rather than copies, so the tool tracks whatever Plume is
/// installed instead of going stale after an upgrade. A link points into the
/// app bundle, which means moving or deleting Plume breaks it — `state`
/// reports that as `.brokenLink` so the UI can offer to relink.
enum CommandLineHelper {
    static let commandNames = ["plume", "plume-notify"]

    /// Not `/usr/local/bin`: writing there needs admin rights, and this
    /// user's shell profile already has `~/.local/bin`.
    static var installDirectory: URL {
        URL.homeDirectory.appending(path: ".local/bin")
    }

    /// The tool inside the app bundle. Nil in a bundle that doesn't carry it.
    ///
    /// In `Contents/Helpers`, not beside the app in `Contents/MacOS`: on a
    /// case-insensitive volume `plume` there *is* the `Plume` executable.
    static var bundledURL: URL? {
        let url = toolURL(inBundle: Bundle.main.bundleURL)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func toolURL(inBundle bundleURL: URL) -> URL {
        bundleURL.appending(path: "Contents/Helpers/plume")
    }

    /// Where the script lived before the tool replaced it.
    static func legacyScriptURL(inBundle bundleURL: URL) -> URL {
        bundleURL.appending(path: "Contents/Resources/plume-notify")
    }

    enum State: Equatable {
        case installed
        case notInstalled
        /// Something else already owns the name — a real file, or a symlink
        /// to another tool. Overwriting it is the user's call, not ours.
        case occupiedByOther(URL?)
        /// A link into a Plume bundle, but not at this build's tool: the old
        /// script, or another copy of Plume. Ours to replace.
        case outdated(URL)
        /// Installed by Plume, but the bundle it pointed at is gone.
        case brokenLink
    }

    static func state(of installedURL: URL, bundledURL: URL? = bundledURL) -> State {
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
        guard manager.fileExists(atPath: resolved.path) else {
            // A dangling link into some app bundle is ours in every case that
            // matters; a dangling link to anything else is equally safe to replace.
            return .brokenLink
        }
        return isInsidePlumeBundle(resolved) ? .outdated(resolved) : .occupiedByOther(resolved)
    }

    static func isInsidePlumeBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasPrefix("Plume") && $0.hasSuffix(".app") }
    }

    /// Every managed name and its state, in `commandNames` order.
    static func states(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL
    ) -> [(name: String, state: State)] {
        commandNames.map { ($0, state(of: directory.appending(path: $0), bundledURL: bundledURL)) }
    }

    enum Summary: Equatable {
        case installed
        case notInstalled
        /// Some names are missing or point at an older or vanished tool.
        case needsUpdate
        case occupied(name: String)
    }

    static func summary(of states: [(name: String, state: State)]) -> Summary {
        if let occupied = states.first(where: { if case .occupiedByOther = $0.state { true } else { false } }) {
            return .occupied(name: occupied.name)
        }
        if states.allSatisfy({ $0.state == .installed }) { return .installed }
        if states.allSatisfy({ $0.state == .notInstalled }) { return .notInstalled }
        return .needsUpdate
    }

    enum InstallError: LocalizedError {
        case notBundled
        case occupied(URL, destination: URL?)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                "This build of \(AppIdentity.displayName) does not carry the plume tool."
            case .occupied(let url, let destination):
                if let destination {
                    "\(url.path) already points at \(destination.path)."
                } else {
                    "\(url.path) already exists."
                }
            }
        }
    }

    /// Links every name, replacing links Plume placed itself. A name that
    /// something else owns is skipped and reported once the rest are linked.
    static func install(in directory: URL = installDirectory, bundledURL: URL? = bundledURL) throws {
        guard let bundledURL else { throw InstallError.notBundled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var firstConflict: InstallError?
        for (name, state) in states(in: directory, bundledURL: bundledURL) {
            let url = directory.appending(path: name)
            switch state {
            case .installed:
                continue
            case .occupiedByOther(let destination):
                firstConflict = firstConflict ?? .occupied(url, destination: destination)
                continue
            case .brokenLink, .outdated:
                try FileManager.default.removeItem(at: url)
            case .notInstalled:
                break
            }
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: bundledURL)
        }
        if let firstConflict { throw firstConflict }
    }

    /// Removes the links Plume placed, leaving anything else alone.
    static func uninstall(in directory: URL = installDirectory, bundledURL: URL? = bundledURL) throws {
        for (name, state) in states(in: directory, bundledURL: bundledURL) {
            switch state {
            case .installed, .outdated:
                try FileManager.default.removeItem(at: directory.appending(path: name))
            case .notInstalled, .occupiedByOther, .brokenLink:
                continue
            }
        }
    }

    /// A `plume-notify` link to this bundle's old script dangles once the
    /// script is gone, so launch repoints it — and, since that user opted in
    /// to the helper, adds `plume` beside it. Links into any other bundle
    /// are left for Settings, so a debug build never claims the installed
    /// app's links.
    static func repointLegacyLinks(
        in directory: URL = installDirectory,
        bundleURL: URL = Bundle.main.bundleURL,
        bundledURL: URL? = bundledURL
    ) {
        guard let bundledURL else { return }
        let link = directory.appending(path: "plume-notify")
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
                == legacyScriptURL(inBundle: bundleURL).standardizedFileURL
        else { return }
        do {
            try install(in: directory, bundledURL: bundledURL)
            Log.app.info("Repointed the plume-notify link at the plume tool")
        } catch {
            Log.app.error("Could not repoint the plume-notify link: \(error.localizedDescription, privacy: .public)")
        }
    }
}
