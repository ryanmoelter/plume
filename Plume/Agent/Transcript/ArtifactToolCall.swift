import Foundation

/// A call to one of Claude Code's Artifact tools, which publish and manage
/// pages hosted on claude.ai.
nonisolated struct ArtifactToolCall: Equatable {
    static let toolNames: Set<String> = ["Artifact", "ArtifactComments", "ArtifactData", "ArtifactCheck"]

    /// Actions that name no single artifact worth opening: a listing, a
    /// quickstart, or one that has just been deleted.
    private static let actionsWithoutALink: Set<String> = ["list", "quickstart", "delete"]

    let action: String
    let inputURL: URL?
    let title: String?

    init?(name: String, input: [String: JSONValue], readsPageTitle: (String) -> String? = Self.pageTitle(atPath:)) {
        guard Self.toolNames.contains(name) else { return nil }
        // `Artifact` treats a missing action as a publish.
        action = input["action"]?.stringValue ?? (name == "Artifact" ? "publish" : "")
        inputURL = input["url"]?.stringValue.flatMap(Self.artifactURL(in:))
        // The page's own `<title>` wins on claude.ai; the input is only the
        // fallback for a page without one.
        let path = action == "publish" ? input["file_path"]?.stringValue : nil
        title = path.flatMap(readsPageTitle) ?? input["title"]?.stringValue.flatMap(Self.nonEmpty)
    }

    /// The artifact this call worked on, once it is known.
    func url(result: String?) -> URL? {
        guard !Self.actionsWithoutALink.contains(action) else { return nil }
        let resultURL = result.flatMap(Self.artifactURL(in:))
        // A first publish has no input url; the result names what it wrote.
        return action == "publish" ? resultURL ?? inputURL : inputURL ?? resultURL
    }

    /// The first claude.ai artifact link in `text`. Only claude.ai hosts
    /// match, since this text is model-facing and the link becomes a click.
    static func artifactURL(in text: String) -> URL? {
        let pattern = #/https://(?:[a-z0-9-]+\.)*claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+/#
        return text.firstMatch(of: pattern).flatMap { URL(string: String($0.output)) }
    }

    /// The `<title>` of a local HTML page, read from its head only.
    static func pageTitle(atPath path: String) -> String? {
        guard path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm"),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return pageTitle(inHTML: String(decoding: head, as: UTF8.self))
    }

    static func pageTitle(inHTML html: String) -> String? {
        let pattern = #/(?is)<title[^>]*>(.*?)</title>/#
        guard let match = html.firstMatch(of: pattern) else { return nil }
        return nonEmpty(String(match.output.1))
    }

    private static func nonEmpty(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

/// One artifact a conversation worked on, for the info pane's list.
nonisolated struct ConversationArtifact: Equatable, Identifiable {
    let url: URL
    let title: String?

    var id: URL { url }

    /// Every linked artifact in `messages`, once each, in the order the
    /// conversation first touched them. A later call's title replaces an
    /// earlier one, since a republish can rename the page.
    static func artifacts(in messages: [ChatMessage]) -> [ConversationArtifact] {
        var order: [URL] = []
        var seen: Set<URL> = []
        var titles: [URL: String] = [:]
        for message in messages {
            for case .toolCall(let call) in message.blocks {
                guard let url = call.artifactURL else { continue }
                if seen.insert(url).inserted { order.append(url) }
                if let title = call.artifact?.title { titles[url] = title }
            }
        }
        return order.map { ConversationArtifact(url: $0, title: titles[$0]) }
    }
}
