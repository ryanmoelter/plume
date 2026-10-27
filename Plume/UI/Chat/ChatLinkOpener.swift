import AppKit
import SwiftUI

/// Opens a link clicked in rendered markdown.
///
/// Two things make the stock behaviour unreliable here. Agent prose cites
/// files the way it writes them — `[MarkdownView.swift](Plume/UI/Chat/MarkdownView.swift)`
/// — and `AttributedString(markdown:)` hands those to SwiftUI as a URL with
/// no scheme, which `NSWorkspace` refuses outright. And the default action
/// calls `NSWorkspace.open` on the thread the click arrives on, so a cold
/// handler app stalls the UI for as long as Launch Services takes.
enum ChatLinkOpener {
    /// Where a clicked link should resolve to, having been given the
    /// directory the conversation is rooted in.
    enum Target: Equatable {
        /// Hand it to `NSWorkspace` as-is.
        case web(URL)
        /// Reveal a path on disk. Separate from `web` because a path that
        /// does not exist should do nothing rather than bounce off Launch
        /// Services.
        case file(URL)
        /// Nothing safe to do — an unsupported scheme, or a relative path
        /// with no base to resolve it against.
        case unopenable
    }

    /// Schemes worth handing to the system. Anything else — `javascript:`
    /// most of all — is refused: chat content is model output, and this is
    /// the boundary where it becomes an action.
    private static let allowedSchemes: Set<String> = [
        "http", "https", "mailto", "ftp", "ftps",
    ]

    /// Resolves a link's URL against the conversation's working directory.
    ///
    /// `base` is nil when the conversation has no directory of its own, which
    /// is why a relative path can end up `unopenable`.
    static func target(for url: URL, relativeTo base: URL?) -> Target {
        if let scheme = url.scheme?.lowercased(), scheme != "file" {
            guard allowedSchemes.contains(scheme) else { return .unopenable }
            return .web(url)
        }
        guard let resolved = resolvedFileURL(for: url, relativeTo: base) else { return .unopenable }
        return fileTarget(resolved)
    }

    /// The file a `file:` or scheme-less link names, without checking that it
    /// exists. Nil for any other scheme, or a relative path with no base.
    nonisolated static func resolvedFileURL(for url: URL, relativeTo base: URL?) -> URL? {
        if let scheme = url.scheme?.lowercased() {
            return scheme == "file" ? url.standardizedFileURL : nil
        }

        // Scheme-less. Either a path the agent wrote, or a bare host like
        // `example.com` that only a path check can tell apart.
        // A `<…>` target with a space arrives percent-encoded.
        let raw = url.absoluteString
        let decoded = raw.removingPercentEncoding ?? raw
        // A fragment is how a file citation carries a line number
        // (`Foo.swift#L42`). Nothing on disk is named that, so it is dropped
        // before the path is resolved.
        let path = String(decoded.split(separator: "#", maxSplits: 1).first ?? "")
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if path.hasPrefix("~") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        }
        guard let base else { return nil }
        return base.appendingPathComponent(path).standardizedFileURL
    }

    /// A file link resolves only if something is actually there. An agent
    /// cites paths it has not created and paths from another checkout, and
    /// opening those would land the user in a Finder error rather than a
    /// no-op.
    private static func fileTarget(_ url: URL) -> Target {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unopenable }
        return .file(url)
    }

    /// Hands the target to the system off the main thread — `NSWorkspace`
    /// blocks its caller while Launch Services starts the handler.
    @MainActor
    static func open(_ target: Target) {
        switch target {
        case .web(let url), .file(let url):
            Task.detached(priority: .userInitiated) {
                NSWorkspace.shared.open(url)
            }
        case .unopenable:
            break
        }
    }
}

private struct ChatLinkDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    /// The directory a clicked link's relative path resolves against. Read by
    /// the custom list, which has to rebuild the handler for each hosted row.
    var chatLinkDirectory: URL? {
        get { self[ChatLinkDirectoryKey.self] }
        set { self[ChatLinkDirectoryKey.self] = newValue }
    }
}

extension View {
    /// Routes markdown links through `ChatLinkOpener`, resolving relative
    /// paths against `directory`.
    func chatLinkHandling(directory: URL?) -> some View {
        environment(\.chatLinkDirectory, directory)
            .environment(\.openURL, OpenURLAction { url in
                ChatLinkOpener.open(ChatLinkOpener.target(for: url, relativeTo: directory))
                return .handled
            })
    }
}
