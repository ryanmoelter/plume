import Foundation

/// The pull requests chat links name, looked up by repository and number
/// with one `gh api graphql` call per repository.
///
/// Answers are cached: an open pull request for `openLifetime`, a merged or
/// closed one for `settledLifetime`, and a definitive miss for
/// `missLifetime`. A failed call that names no missing pull request is
/// retried with backoff, then answers nothing and caches nothing.
actor PullRequestLinkSource {
    static let shared = PullRequestLinkSource()

    static let openLifetime: TimeInterval = 600
    static let settledLifetime: TimeInterval = 3600
    static let missLifetime: TimeInterval = 600
    static let retryDelays: [Duration] = [.milliseconds(500), .seconds(2)]
    static let batchLimit = 50

    struct Key: Hashable, Sendable {
        let owner: String
        let repo: String
        let number: Int

        /// GitHub reads owner and repository names case-insensitively.
        init(owner: String, repo: String, number: Int) {
            self.owner = owner.lowercased()
            self.repo = repo.lowercased()
            self.number = number
        }
    }

    struct Entry: Equatable, Sendable {
        let number: Int
        let title: String
        let state: PullRequestState
        let isDraft: Bool
    }

    enum Lookup: Equatable, Sendable {
        case found(Entry)
        /// The repository has no such pull request, or isn't visible.
        case missing
    }

    typealias Runner = @Sendable (_ arguments: [String]) async throws -> Data

    private struct Cached {
        let lookup: Lookup
        let at: Date
    }

    private var cache: [Key: Cached] = [:]
    private let run: Runner
    private let sleep: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> Date

    init(
        run: @escaping Runner = PullRequestLinkSource.runGH,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.run = run
        self.sleep = sleep
        self.now = now
    }

    static let runGH: Runner = { arguments in
        try await GHCommand.run(arguments: arguments, in: NSHomeDirectory(), timeout: .seconds(15))
    }

    /// An answer for each key `gh` gave one for. A key left out had no
    /// answer, and is worth asking about again later.
    func lookUp(_ keys: Set<Key>) async -> [Key: Lookup] {
        var answers: [Key: Lookup] = [:]
        var wanted: [String: [Key]] = [:]
        for key in keys {
            if let cached = cache[key], now().timeIntervalSince(cached.at) < Self.lifetime(of: cached.lookup) {
                answers[key] = cached.lookup
            } else {
                wanted["\(key.owner)/\(key.repo)", default: []].append(key)
            }
        }
        for repository in wanted.keys.sorted() {
            let keys = wanted[repository]!.sorted { $0.number < $1.number }
            for start in stride(from: 0, to: keys.count, by: Self.batchLimit) {
                let batch = Array(keys[start..<min(start + Self.batchLimit, keys.count)])
                for (key, lookup) in await fetch(batch) {
                    cache[key] = Cached(lookup: lookup, at: now())
                    answers[key] = lookup
                }
            }
        }
        return answers
    }

    private static func lifetime(of lookup: Lookup) -> TimeInterval {
        switch lookup {
        case .found(let entry): entry.state == .open ? openLifetime : settledLifetime
        case .missing: missLifetime
        }
    }

    /// `keys` all share one repository.
    private func fetch(_ keys: [Key]) async -> [Key: Lookup] {
        var answers: [Key: Lookup] = [:]
        var remaining = keys
        var retries = Self.retryDelays[...]
        while !remaining.isEmpty, !Task.isCancelled {
            do {
                let data = try await run(Self.arguments(for: remaining))
                guard let decoded = Self.decode(data, numbers: remaining.map(\.number)) else { return answers }
                for key in remaining { answers[key] = decoded[key.number] ?? .missing }
                return answers
            } catch {
                let message = (error as? ForgeError)?.message ?? ""
                if Self.namesMissingRepository(message) {
                    for key in remaining { answers[key] = .missing }
                    return answers
                }
                let missing = Self.missingNumbers(in: message)
                if !missing.isEmpty {
                    for key in remaining where missing.contains(key.number) { answers[key] = .missing }
                    remaining.removeAll { missing.contains($0.number) }
                    continue
                }
                guard let delay = retries.popFirst() else { return answers }
                await sleep(delay)
            }
        }
        return answers
    }

    static func arguments(for keys: [Key]) -> [String] {
        let fields = keys.map { "p\($0.number): pullRequest(number: \($0.number)) { number title url state isDraft }" }
        let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) } }"
        // `-f`, not `-F`: `-F` would read a numeric repository name as a
        // number.
        return ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(keys[0].owner)", "-f", "name=\(keys[0].repo)"]
    }

    /// Nil for a body that isn't the shape asked for. A number absent from
    /// the result means GitHub answered null for it.
    static func decode(_ data: Data, numbers: [Int]) -> [Int: Lookup]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any]
        else { return nil }
        guard let repository = payload["repository"] as? [String: Any] else {
            return Dictionary(uniqueKeysWithValues: numbers.map { ($0, .missing) })
        }
        var lookups: [Int: Lookup] = [:]
        for number in numbers {
            guard let pull = repository["p\(number)"] as? [String: Any],
                  let title = pull["title"] as? String,
                  let state = (pull["state"] as? String).flatMap(PullRequestState.init(rawValue:))
            else {
                lookups[number] = .missing
                continue
            }
            lookups[number] = .found(Entry(number: number, title: title, state: state, isDraft: pull["isDraft"] as? Bool ?? false))
        }
        return lookups
    }

    static func missingNumbers(in message: String) -> Set<Int> {
        let ns = message as NSString
        return Set(missingPullRequestPattern.matches(in: message, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        })
    }

    static func namesMissingRepository(_ message: String) -> Bool {
        message.contains("Could not resolve to a Repository")
    }

    private static let missingPullRequestPattern = try! NSRegularExpression(
        pattern: #"Could not resolve to a PullRequest with the number of (\d+)"#
    )
}
