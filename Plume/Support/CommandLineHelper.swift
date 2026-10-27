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
nonisolated enum CommandLineHelper {
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
        /// to another tool, even one that has since gone. Overwriting it is
        /// the user's call, not ours.
        case occupiedByOther(URL?)
        /// A link into another Plume bundle that this build doesn't claim.
        case ownedByOtherPlume(URL)
        /// A link into a Plume bundle, but not at this build's tool: the old
        /// script, or another copy of Plume. Ours to replace.
        case outdated(URL)
        /// A link into a Plume bundle that is gone.
        case brokenLink

        /// A link Plume placed and may remove.
        var isPlumeOwned: Bool {
            switch self {
            case .installed, .outdated: true
            case .notInstalled, .occupiedByOther, .ownedByOtherPlume, .brokenLink: false
            }
        }

        /// A link to a Plume tool that exists, whoever placed it.
        var isLinked: Bool {
            switch self {
            case .installed, .outdated, .ownedByOtherPlume: true
            case .notInstalled, .occupiedByOther, .brokenLink: false
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
        guard isInsidePlumeBundle(resolved) else { return .occupiedByOther(resolved) }
        guard manager.fileExists(atPath: resolved.path) else { return .brokenLink }
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

    /// What the Command line tool switch in Settings shows and offers.
    struct Summary: Equatable {
        /// True while any name links to a Plume tool, this build's or another copy's.
        var isOn: Bool
        /// False when flipping the switch could change nothing: on only through
        /// another copy of Plume's links, which a debug build leaves alone, or
        /// off with every name taken.
        var canToggle: Bool
        /// Plume owns a link, but some name is missing or points at an older
        /// or vanished tool.
        var needsUpdate: Bool
        var notes: [String]
    }

    static func summary(of states: [(name: String, state: State)]) -> Summary {
        let isOn = states.contains { $0.state.isLinked }
        let ownsALink = states.contains { $0.state.isPlumeOwned }
        let available = states.filter { !$0.state.isTaken }
        let needsUpdate = ownsALink && available.contains { $0.state != .installed }
        var notes = states.compactMap { entry -> String? in
            switch entry.state {
            case .occupiedByOther: "Another tool owns \(entry.name)"
            case .ownedByOtherPlume: "Another copy of Plume owns \(entry.name)"
            case .installed, .notInstalled, .outdated, .brokenLink: nil
            }
        }
        if needsUpdate { notes.append("Needs updating") }
        return Summary(
            isOn: isOn,
            canToggle: isOn ? ownsALink : !available.isEmpty,
            needsUpdate: needsUpdate,
            notes: notes
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

    /// Removes every link Plume owns, `wt` included, since a `wt` left behind
    /// would keep part of the tool on PATH with its switch off. A dangling
    /// link is removed only when it pointed into a Plume bundle.
    static func uninstall(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) throws {
        var entries = states(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles)
        entries.append(
            (wtCommandName, wtState(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles))
        )
        for (name, state) in entries {
            let url = directory.appending(path: name)
            if state.isPlumeOwned || (state == .brokenLink && linksIntoPlumeBundle(url)) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func linksIntoPlumeBundle(_ url: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        return isInsidePlumeBundle(URL(fileURLWithPath: destination, relativeTo: url).standardizedFileURL)
    }

    /// A `plume-notify` link to this bundle's old script dangles once the
    /// script is gone, so launch repoints it — and, since that user opted in
    /// to the helper, adds `plume` beside it. Links into any other bundle
    /// are left for Settings, so a debug build never claims the installed
    /// app's links.
    ///
    /// Returns whether each name now links to the tool, empty when there was
    /// nothing to repoint.
    @MainActor @discardableResult
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

    // MARK: wt

    /// Invoked as `wt`, the tool runs `plume wt`. Linked only when the user
    /// asks, never by `install` or at launch, because `wt` is a common name
    /// that another tool may already own.
    static let wtCommandName = "wt"

    /// As `state(of:)`, except that a dangling link outside any Plume bundle
    /// is someone else's: it may be the user's own `wt`, moved.
    static func wtState(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) -> State {
        let url = directory.appending(path: wtCommandName)
        let state = state(of: url, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles)
        guard state == .brokenLink, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return state }
        let resolved = URL(fileURLWithPath: destination, relativeTo: url).standardizedFileURL
        return isInsidePlumeBundle(resolved) ? state : .occupiedByOther(resolved)
    }

    struct WTSummary: Equatable {
        var status: String
        /// Nil when there is nothing to link.
        var installTitle: String?
        var canRemove: Bool
    }

    static func wtSummary(of state: State) -> WTSummary {
        switch state {
        case .installed: WTSummary(status: "Linked", installTitle: nil, canRemove: true)
        case .notInstalled: WTSummary(status: "Not linked", installTitle: "Link", canRemove: false)
        case .outdated: WTSummary(status: "Needs updating", installTitle: "Update", canRemove: true)
        case .brokenLink: WTSummary(status: "Needs updating", installTitle: "Update", canRemove: false)
        case .occupiedByOther: WTSummary(status: "Another tool owns wt", installTitle: nil, canRemove: false)
        case .ownedByOtherPlume: WTSummary(status: "Another copy of Plume owns wt", installTitle: nil, canRemove: false)
        }
    }

    static func installWT(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) throws {
        guard let bundledURL else { throw InstallError.notBundled }
        let url = directory.appending(path: wtCommandName)
        switch wtState(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles) {
        case .installed:
            return
        case .occupiedByOther(let destination):
            throw InstallError.occupied(url, destination: destination)
        case .ownedByOtherPlume(let destination):
            throw InstallError.occupied(url, destination: destination)
        case .brokenLink, .outdated:
            try FileManager.default.removeItem(at: url)
        case .notInstalled:
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: bundledURL)
    }

    static func uninstallWT(
        in directory: URL = installDirectory,
        bundledURL: URL? = bundledURL,
        claimsOtherPlumeBundles: Bool = claimsOtherPlumeBundles
    ) throws {
        guard wtState(in: directory, bundledURL: bundledURL, claimsOtherPlumeBundles: claimsOtherPlumeBundles).isPlumeOwned
        else { return }
        try FileManager.default.removeItem(at: directory.appending(path: wtCommandName))
    }

    @MainActor private static func logLinkFailure(_ url: URL, _ error: Error?) {
        let reason = error?.localizedDescription ?? "unknown error"
        Log.app.error("Could not link \(url.path, privacy: .public) to the plume tool: \(reason, privacy: .public)")
    }
}
