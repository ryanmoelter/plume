import Foundation

/// The pull requests the user pinned to a task, stored in its
/// `TaskIntegrations`.
nonisolated struct PullRequestTaskLinks: Codable, Equatable {
    var pinned: [PullRequestReference] = []

    init(pinned: [PullRequestReference] = []) {
        self.pinned = pinned
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = container.decodeLossyArray(PullRequestReference.self, forKey: .pinned)
    }

    var isEmpty: Bool { pinned.isEmpty }

    mutating func pin(_ reference: PullRequestReference) {
        if !pinned.contains(reference) { pinned.append(reference) }
    }

    mutating func unpin(_ reference: PullRequestReference) {
        pinned.removeAll { $0 == reference }
    }
}

extension PullRequestReference: Codable {
    private enum CodingKeys: String, CodingKey {
        case owner, repo, number
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            owner: try container.decode(String.self, forKey: .owner),
            repo: try container.decode(String.self, forKey: .repo),
            number: try container.decode(Int.self, forKey: .number)
        )
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(repo, forKey: .repo)
        try container.encode(number, forKey: .number)
    }

    /// Reads a pull request URL, or `owner/repo#123`.
    nonisolated static func parse(_ text: String) -> PullRequestReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = ConversationReferenceScanner.references(in: trimmed).pullRequests.first {
            return found
        }
        let whole = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = shorthandPattern.firstMatch(in: trimmed, range: whole),
              let number = Int((trimmed as NSString).substring(with: match.range(at: 3))), number > 0
        else { return nil }
        let ns = trimmed as NSString
        return PullRequestReference(
            owner: ns.substring(with: match.range(at: 1)),
            repo: ns.substring(with: match.range(at: 2)),
            number: number
        )
    }

    private nonisolated static let shorthandPattern = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)#([0-9]{1,9})$"#
    )
}

nonisolated enum LinkedPullRequestRole: Equatable, Sendable {
    case pinned
    /// Named in the conversation but not pinned.
    case mentioned
}

nonisolated struct LinkedPullRequest: Equatable, Sendable, Identifiable {
    let reference: PullRequestReference
    let role: LinkedPullRequestRole

    var id: String { reference.id }

    /// Pinned first, each in its own order. A pinned pull request the
    /// conversation also names shows once, as pinned.
    static func merge(pinned: [PullRequestReference], mentioned: [PullRequestReference]) -> [LinkedPullRequest] {
        var seen: Set<PullRequestReference> = []
        var result: [LinkedPullRequest] = []
        for reference in pinned where seen.insert(reference).inserted {
            result.append(LinkedPullRequest(reference: reference, role: .pinned))
        }
        for reference in mentioned where seen.insert(reference).inserted {
            result.append(LinkedPullRequest(reference: reference, role: .mentioned))
        }
        return result
    }
}
