import Foundation

/// What a `MentionReference` names, once something has vouched for it.
nonisolated struct ResolvedMention: Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// `colorHex` is a `#rrggbb` string, as Linear reports it.
        case linear(LinearStateType, colorHex: String)
        case pullRequest(PullRequestState, isDraft: Bool)
        case file(isDirectory: Bool)
    }

    /// A URL, or a file's path relative to the tab directory, or absolute
    /// with `~` expanded.
    let target: String
    let title: String?
    let state: State
}

/// Turns each resolved reference in a message into a Markdown link, leaving
/// the rest as typed.
nonisolated enum MentionExpansion {
    static func expanding(_ text: String, resolve: (MentionReference.Kind) -> ResolvedMention?) -> String {
        let references = MentionReference.references(in: text)
        guard !references.isEmpty else { return text }
        let expanded = NSMutableString(string: text)
        for reference in references.reversed() {
            guard let resolution = resolve(reference.kind) else { continue }
            let link = MentionInsertion.link(label: label(for: reference.kind), target: resolution.target)
            expanded.replaceCharacters(in: reference.range, with: link)
        }
        return expanded as String
    }

    /// `DROID-123`, `#123`, or the file's name, with a folder's trailing `/`.
    static func label(for kind: MentionReference.Kind) -> String {
        switch kind {
        case .linear(let identifier): return identifier
        case .pullRequest(let number): return "#\(number)"
        case .file(let path, let isDirectory):
            let name = path == "/" ? "/" : (path as NSString).lastPathComponent
            return isDirectory && name != "/" ? name + "/" : name
        }
    }
}

/// Resolves references for a tab: Linear issues from `LinearStore`'s cache,
/// pull requests from `PullRequestMentionSource`, and files by checking that
/// they exist under the tab directory.
///
/// A row accepted from the mention menu is remembered per tab, and so is
/// every answer `resolve` finds, so sending reads `cachedResolution` alone and
/// never waits on a lookup. A reference nothing has vouched for is sent as
/// typed.
@MainActor
final class MentionResolver {
    static let shared = MentionResolver()

    struct Dependencies {
        var linearIssue: @MainActor (String) -> MentionCandidate.LinearIssue?
        /// Fetches an identifier the cache lacks, for `linearIssue` to find.
        var lookUpLinear: @MainActor (String) async -> Void
        var pullRequest: @Sendable (_ number: Int, _ directory: String) async -> MentionCandidate.PullRequestEntry?
        /// Nil when nothing is there, otherwise whether it is a folder.
        var fileIsDirectory: @Sendable (_ absolutePath: String) -> Bool?
        var homeDirectory: String

        static let live = Dependencies(
            linearIssue: { LinearStore.shared.mentionIssue(identifier: $0) },
            lookUpLinear: { await LinearStore.shared.searchIssues($0) },
            pullRequest: { await PullRequestMentionSource.shared.pullRequest(number: $0, in: $1) },
            fileIsDirectory: { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
                return isDirectory.boolValue
            },
            homeDirectory: NSHomeDirectory()
        )
    }

    static let maxResolvedPerTab = 500

    private var remembered: [UUID: [MentionReference.Kind: ResolvedMention]] = [:]
    private var resolved: [UUID: [MentionReference.Kind: ResolvedMention]] = [:]
    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func remember(_ resolution: ResolvedMention, for kind: MentionReference.Kind, tabID: UUID) {
        remembered[tabID, default: [:]][kind] = resolution
    }

    func forgetTab(_ tabID: UUID) {
        remembered[tabID] = nil
        resolved[tabID] = nil
    }

    /// What is known without a request or a disk read.
    func cachedResolution(of kind: MentionReference.Kind, tabID: UUID) -> ResolvedMention? {
        if let resolution = remembered[tabID]?[kind] ?? resolved[tabID]?[kind] { return resolution }
        if case .linear(let identifier) = kind, let issue = dependencies.linearIssue(identifier) {
            return ResolvedMention(issue)
        }
        return nil
    }

    func resolve(_ kind: MentionReference.Kind, tabID: UUID, directory: String?) async -> ResolvedMention? {
        if let cached = cachedResolution(of: kind, tabID: tabID) { return cached }
        let resolution: ResolvedMention?
        switch kind {
        case .linear(let identifier):
            await dependencies.lookUpLinear(identifier)
            resolution = dependencies.linearIssue(identifier).map(ResolvedMention.init)
        case .pullRequest(let number):
            guard let directory else { return nil }
            resolution = await dependencies.pullRequest(number, directory).map(ResolvedMention.init)
        case .file(let path, _):
            let target = MentionInsertion.expandingTilde(path, homeDirectory: dependencies.homeDirectory)
            let absolute: String
            if target.hasPrefix("/") {
                absolute = target
            } else if let directory {
                absolute = (directory as NSString).appendingPathComponent(target)
            } else {
                return nil
            }
            let check = dependencies.fileIsDirectory
            let isDirectory = await Task.detached(priority: .userInitiated) { check(absolute) }.value
            resolution = isDirectory.map { ResolvedMention(target: target, title: nil, state: .file(isDirectory: $0)) }
        }
        if let resolution { store(resolution, for: kind, tabID: tabID) }
        return resolution
    }

    /// `text` with each reference known for the tab as a Markdown link.
    func expandingReferences(in text: String, tabID: UUID) -> String {
        MentionExpansion.expanding(text) { cachedResolution(of: $0, tabID: tabID) }
    }

    private func store(_ resolution: ResolvedMention, for kind: MentionReference.Kind, tabID: UUID) {
        if (resolved[tabID]?.count ?? 0) >= Self.maxResolvedPerTab { resolved[tabID] = [:] }
        resolved[tabID, default: [:]][kind] = resolution
    }
}

extension ResolvedMention {
    nonisolated init(_ issue: MentionCandidate.LinearIssue) {
        self.init(target: issue.url, title: issue.title, state: .linear(issue.stateType, colorHex: issue.stateColor))
    }

    nonisolated init(_ pull: MentionCandidate.PullRequestEntry) {
        self.init(target: pull.url, title: pull.title, state: .pullRequest(pull.state, isDraft: pull.isDraft))
    }
}

extension MentionCandidate {
    /// The reference accepting this row leaves, and what it resolves to.
    /// Nil for a filter row.
    nonisolated func resolvedReference(homeDirectory: String) -> (MentionReference.Kind, ResolvedMention)? {
        switch self {
        case .linear(let issue):
            return (.linear(identifier: issue.identifier.uppercased()), ResolvedMention(issue))
        case .pullRequest(let pull):
            return (.pullRequest(number: pull.number), ResolvedMention(pull))
        case .file(let entry):
            var path = entry.path
            if entry.isDirectory, path.count > 1, path.hasSuffix("/") { path.removeLast() }
            let target = MentionInsertion.expandingTilde(path, homeDirectory: homeDirectory)
            return (
                .file(path: path, isDirectory: entry.isDirectory),
                ResolvedMention(target: target, title: nil, state: .file(isDirectory: entry.isDirectory))
            )
        case .filter:
            return nil
        }
    }
}
