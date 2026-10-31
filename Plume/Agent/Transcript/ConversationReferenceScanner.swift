import Foundation

/// A GitHub pull request a conversation links to. Owner and repository are
/// lowercased, since GitHub matches them case-insensitively.
nonisolated struct PullRequestReference: Hashable, Sendable, Identifiable {
    let owner: String
    let repo: String
    let number: Int

    init(owner: String, repo: String, number: Int) {
        self.owner = owner.lowercased()
        self.repo = repo.lowercased()
        self.number = number
    }

    var url: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }
    var id: String { url }

    /// Whether `url` names this pull request, in any case and with any suffix.
    func matches(url: String?) -> Bool {
        guard let url, let found = ConversationReferenceScanner.references(in: url).pullRequests.first else { return false }
        return found == self
    }
}

/// What a conversation's prose names.
nonisolated struct ConversationReferences: Equatable, Sendable {
    /// Uppercased and unfiltered: a bare `KEY-123` only counts once a
    /// connected workspace has the team key, which `LinearLinkResolver`
    /// decides, so `UTF-8` is collected here and dropped there.
    var linearIdentifiers: [String] = []
    var pullRequests: [PullRequestReference] = []

    var isEmpty: Bool { linearIdentifiers.isEmpty && pullRequests.isEmpty }

    mutating func formUnion(_ other: ConversationReferences) {
        for id in other.linearIdentifiers where !linearIdentifiers.contains(id) { linearIdentifiers.append(id) }
        for pull in other.pullRequests where !pullRequests.contains(pull) { pullRequests.append(pull) }
    }
}

/// Finds Linear issues and pull requests in the prose of a conversation: the
/// user's messages, pasted text included, and the assistant's replies. Tool
/// input and output, thinking and other injected content are left out, since they quote whole files and command
/// output that name issues the conversation is not about.
///
/// An accepted `@` mention reaches the transcript as a Markdown link to its
/// URL, so it counts through the same scan as a pasted link.
nonisolated enum ConversationReferenceScanner {
    /// Scan results per message id, so a re-parse of the whole transcript
    /// only scans messages that are new or have grown since.
    struct Cache: Sendable {
        fileprivate var entries: [String: Entry] = [:]
    }

    fileprivate struct Entry: Sendable {
        let fingerprint: Fingerprint
        let references: ConversationReferences
    }

    /// A message only ever grows, by blocks folded into it or a block
    /// streaming longer, so its size stands in for its content.
    fileprivate struct Fingerprint: Equatable, Sendable {
        let blocks: Int
        let length: Int
    }

    static func scan(_ messages: [ChatMessage], cache: inout Cache) -> ConversationReferences {
        var result = ConversationReferences()
        var entries: [String: Entry] = [:]
        for message in messages where message.role != .notice {
            let texts = message.blocks.compactMap { block -> String? in
                switch block {
                case .markdown(let text): text
                case .injected(let content, let text) where content.isUserProse: text
                default: nil
                }
            }
            let fingerprint = Fingerprint(blocks: message.blocks.count, length: texts.reduce(0) { $0 + $1.utf16.count })
            let references: ConversationReferences
            if let cached = cache.entries[message.id], cached.fingerprint == fingerprint {
                references = cached.references
            } else {
                references = texts.reduce(into: ConversationReferences()) { $0.formUnion(Self.references(in: $1)) }
            }
            entries[message.id] = Entry(fingerprint: fingerprint, references: references)
            result.formUnion(references)
        }
        cache.entries = entries
        return result
    }

    static func references(in text: String) -> ConversationReferences {
        var result = ConversationReferences()
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // Linear URLs come first so a lowercase identifier in one still counts.
        for match in linearURLPattern.matches(in: text, range: whole) {
            if let id = LinearIdentifier.normalize(ns.substring(with: match.range(at: 1))),
               !result.linearIdentifiers.contains(id) {
                result.linearIdentifiers.append(id)
            }
        }
        for match in identifierPattern.matches(in: text, range: whole) {
            let id = ns.substring(with: match.range)
            if !result.linearIdentifiers.contains(id) { result.linearIdentifiers.append(id) }
        }
        for match in pullRequestPattern.matches(in: text, range: whole) {
            guard let number = PullRequestMentionSource.number(in: ns.substring(with: match.range(at: 3))) else { continue }
            let pull = PullRequestReference(
                owner: ns.substring(with: match.range(at: 1)),
                repo: ns.substring(with: match.range(at: 2)),
                number: number
            )
            if !result.pullRequests.contains(pull) { result.pullRequests.append(pull) }
        }
        return result
    }

    private static let linearURLPattern = try! NSRegularExpression(
        pattern: #"linear\.app/[A-Za-z0-9_-]+/issue/([A-Za-z][A-Za-z0-9]{0,6}-[0-9]+)(?![0-9])"#,
        options: .caseInsensitive
    )

    /// Uppercase only, as Linear writes them, so prose like `step-1` never
    /// reads as an issue of a team keyed `STEP`.
    private static let identifierPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])[A-Z][A-Z0-9]{0,6}-[0-9]+(?![A-Za-z0-9_])"#
    )

    private static let pullRequestPattern = try! NSRegularExpression(
        pattern: #"github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(?![0-9])"#,
        options: .caseInsensitive
    )
}
