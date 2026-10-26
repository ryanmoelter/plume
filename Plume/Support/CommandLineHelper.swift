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
        /// A link into another Plume bundle that this build doesn't claim.
        case ownedByOtherPlume(URL)
        /// A link into a Plume bundle, but not at this build's tool: the old
        /// script, or another copy of Plume. Ours to replace.
        case outdated(URL)
        /// Installed by Plume, but the bundle it pointed at is gone.
        case brokenLink

        /// A link Plume placed and may remove.
        var isPlumeOwned: Bool {
            switch self {
            case .installed, .outdated: true
            case .notInstalled, .occupiedByOther, .ownedByOtherPlume, .brokenLink: false
            }
        }

        var isTaken: Bool {
            switch self {
            case .occupiedByOther, .ownedByOtherPlume: true
            case .installed, .notInstalled, .outdated, .brokenLink: false
            }
        }
    }

    /// A release build takes over any Plume bundle's links, since the app may
    /// have moved. A debug build — DerivedData, a worktree — claims only its
    /// own, so it never repoints the installed app's tool at itself.
    static var claimsOtherPlumeBundles: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static func state(
        of installedURL: URL,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
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
        guard manager.fileExists(atPath: resolved.path) else {
            // A dangling link into some app bundle is ours in every case that
            // matters; a dangling link to anything else is equally safe to replace.
            return .brokenLink
        }
        guard isInsidePlumeBundle(resolved) else { return .occupiedByOther(resolved) }
        if claimsOtherPlumeBundles { return .outdated(resolved) }
        if let bundledURL, isInside(resolved, bundle: bundleURL(containingTool: bundledURL)) {
            return .outdated(resolved)
        }
        return .ownedByOtherPlume(resolved)
    }

    static func isInsidePlumeBundle(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.hasPrefix("Plume") && $0.hasSuffix(".app") }
    }

    /// The inverse of `toolURL(inBundle:)`.
    static func bundleURL(containingTool toolURL: URL) -> URL {
        toolURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func isInside(_ url: URL, bundle: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: bundle.standardizedFileURL.pathComponents)
    }

    /// Every managed name and its state, in `commandNames` order.
    static func states(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) -> [(name: String, state: State)] {
        commandNames.map { name in
            let url = directory.appending(path: name)
            return (name, state(of: url, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles))
        }
    }

    /// What Settings shows and offers. Names something else owns are listed
    /// in `taken`, and `progress` covers the rest.
    struct Summary: Equatable {
        enum Progress: Equatable {
            case installed
            case notInstalled
            /// Some names are missing or point at an older or vanished tool.
            case needsUpdate
            /// Every name is taken, so there is nothing to install.
            case allTaken
        }

        struct Taken: Equatable {
            var name: String
            var byOtherPlume: Bool
        }

        var progress: Progress
        /// The names `progress` covers.
        var available: [String]
        var taken: [Taken] = []
        /// True while any link is Plume's, so Remove stays reachable even
        /// when another name is taken.
        var canRemove: Bool

        /// Nil when there is nothing left to link.
        var installTitle: String? {
            switch progress {
            case .notInstalled: "Install"
            case .needsUpdate: "Update"
            case .installed, .allTaken: nil
            }
        }

        var statusLines: [String] {
            var lines: [String] = []
            let progressText: String? = switch progress {
            case .installed: "Installed"
            case .notInstalled: "Not installed"
            case .needsUpdate: "Needs updating"
            case .allTaken: nil
            }
            if let progressText {
                lines.append(taken.isEmpty ? progressText : "\(available.joined(separator: ", ")): \(progressText.lowercased())")
            }
            for entry in taken {
                lines.append("\(entry.byOtherPlume ? "Another copy of Plume" : "Another tool") owns \(entry.name)")
            }
            return lines
        }
    }

    static func summary(of states: [(name: String, state: State)]) -> Summary {
        let taken = states.compactMap { entry -> Summary.Taken? in
            switch entry.state {
            case .occupiedByOther: Summary.Taken(name: entry.name, byOtherPlume: false)
            case .ownedByOtherPlume: Summary.Taken(name: entry.name, byOtherPlume: true)
            case .installed, .notInstalled, .outdated, .brokenLink: nil
            }
        }
        let available = states.filter { !$0.state.isTaken }
        let progress: Summary.Progress =
            if available.isEmpty { .allTaken }
            else if available.allSatisfy({ $0.state == .installed }) { .installed }
            else if available.allSatisfy({ $0.state == .notInstalled }) { .notInstalled }
            else { .needsUpdate }
        return Summary(
            progress: progress,
            available: available.map(\.name),
            taken: taken,
            canRemove: states.contains { $0.state.isPlumeOwned }
        )
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
    static func install(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) throws {
        guard let bundledURL else { throw InstallError.notBundled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var firstConflict: InstallError?
        for (name, state) in states(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles) {
            let url = directory.appending(path: name)
            switch state {
            case .installed:
                continue
            case .occupiedByOther(let destination):
                firstConflict = firstConflict ?? .occupied(url, destination: destination)
                continue
            case .ownedByOtherPlume(let destination):
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
    static func uninstall(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) throws {
        for (name, state) in states(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles)
        where state.isPlumeOwned {
            try FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// A `plume-notify` link to this bundle's old script dangles once the
    /// script is gone, so launch repoints it — and, since that user opted in
    /// to the helper, adds `plume` beside it. Links into any other bundle
    /// are left for Settings, so a debug build never claims the installed
    /// app's links.
    ///
    /// Returns whether each name now links to the tool, empty when there was
    /// nothing to repoint.
    @discardableResult
    static func repointLegacyLinks(
        in directory: URL = installDirectory,
        bundleURL: URL = Bundle.main.bundleURL,
        bundledURL: URL? = bundledURL
    ) -> [(name: String, isLinked: Bool)] {
        guard let bundledURL else { return [] }
        let link = directory.appending(path: "plume-notify")
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            URL(fileURLWithPath: destination, relativeTo: link).standardizedFileURL
                == legacyScriptURL(inBundle: bundleURL).standardizedFileURL
        else { return [] }
        var installError: Error?
        do {
            try install(in: directory, bundledURL: bundledURL)
        } catch {
            installError = error
        }
        return states(in: directory, bundledURL: bundledURL).map { name, state in
            let url = directory.appending(path: name)
            switch state {
            case .installed:
                Log.app.info("\(url.path, privacy: .public) links to the plume tool")
                return (name, true)
            case .occupiedByOther(let destination):
                logLinkFailure(url, InstallError.occupied(url, destination: destination))
            case .ownedByOtherPlume(let destination):
                logLinkFailure(url, InstallError.occupied(url, destination: destination))
            case .notInstalled, .outdated, .brokenLink:
                logLinkFailure(url, installError)
            }
            return (name, false)
        }
    }

    private static func logLinkFailure(_ url: URL, _ error: Error?) {
        let reason = error?.localizedDescription ?? "unknown error"
        Log.app.error("Could not link \(url.path, privacy: .public) to the plume tool: \(reason, privacy: .public)")
    }
}
