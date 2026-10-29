import Foundation

/// Ranks file and folder paths against a mention query: an exact name, then
/// a name prefix, then a prefix for each `/`-separated part in order, then a
/// word start inside the name. A query that looks like a path also matches as
/// a subsequence of the whole path; any other would match too much of a
/// large tree, and the menu's top row is what Return accepts.
nonisolated enum FileMentionMatcher {
    static let defaultLimit = 20
    static let folderPenalty = 0.5

    /// An entry with the lowercased forms matching reads, so a listing
    /// computes them once rather than on every keystroke.
    struct Prepared: Sendable {
        let entry: MentionCandidate.FileEntry
        let components: [String]

        init(_ entry: MentionCandidate.FileEntry) {
            self.entry = entry
            components = entry.path.lowercased().split(separator: "/").map(String.init)
        }
    }

    static func matches(
        _ query: String,
        in entries: [MentionCandidate.FileEntry],
        limit: Int = defaultLimit
    ) -> [RankedMention] {
        matches(query, in: entries.map(Prepared.init), limit: limit)
    }

    static func matches(
        _ query: String,
        in entries: [Prepared],
        limit: Int = defaultLimit
    ) -> [RankedMention] {
        guard limit > 0 else { return [] }
        let pattern = Pattern(query)
        // A bare `@` matches every entry, so keep only the best `limit` rather
        // than sorting a listing that can hold 200,000 paths.
        var best: [Scored] = []
        best.reserveCapacity(limit + 1)
        for (index, prepared) in entries.enumerated() {
            if index % 4096 == 4095, Task.isCancelled { return [] }
            guard let (quality, score) = pattern.match(prepared) else { continue }
            let entry = prepared.entry
            let scored = Scored(
                quality: quality,
                score: entry.isDirectory ? score - folderPenalty : score,
                entry: entry,
                length: entry.path.count
            )
            if best.count == limit, let last = best.last, !scored.ranksAhead(of: last) { continue }
            best.insert(scored, at: best.firstIndex { scored.ranksAhead(of: $0) } ?? best.count)
            if best.count > limit { best.removeLast() }
        }
        return best.map { RankedMention(candidate: .file($0.entry), quality: $0.quality) }
    }

    private struct Scored {
        let quality: MentionMatchQuality
        let score: Double
        let entry: MentionCandidate.FileEntry
        let length: Int

        func ranksAhead(of other: Scored) -> Bool {
            if quality != other.quality { return quality < other.quality }
            if score != other.score { return score > other.score }
            if length != other.length { return length < other.length }
            return entry.path < other.entry.path
        }
    }

    private struct Pattern {
        let whole: [Character]
        /// The part being typed: what follows the last `/`.
        let name: String
        /// The parts before it, which must start the path's folders in order.
        let folders: [String]
        let isPathLike: Bool

        init(_ query: String) {
            var text = query.trimmingCharacters(in: .whitespaces).lowercased()
            isPathLike = text.contains("/") || text.contains(".") || text.hasPrefix("~")
            if text.hasPrefix("./") { text.removeFirst(2) }
            whole = Array(text)
            let parts = text.split(separator: "/").map(String.init)
            if text.hasSuffix("/") || parts.isEmpty {
                name = ""
                folders = parts
            } else {
                name = parts[parts.count - 1]
                folders = Array(parts.dropLast())
            }
        }

        func match(_ prepared: Prepared) -> (MentionMatchQuality, Double)? {
            let components = prepared.components
            guard let entryName = components.last else { return nil }
            let depth = Double(components.count)
            let foldersMatch = Self.startsInOrder(folders, components.dropLast())

            if whole.isEmpty { return (.loose, -depth) }
            if foldersMatch, !name.isEmpty, entryName == name { return (.exact, -depth) }
            if foldersMatch, entryName.hasPrefix(name) {
                return (.prefix, -depth - Double(entryName.count - name.count) * 0.01)
            }
            // A trailing `/` asks for what is inside the folder typed, not
            // for anything that merely resembles it.
            if name.isEmpty { return nil }
            if Self.startsInOrder(folders + [name], components[...]) { return (.words, -depth) }
            if folders.isEmpty, Self.startsAWord(name, in: prepared.entry.name) { return (.words, -depth - 1) }
            guard isPathLike else { return nil }
            if let score = Self.subsequenceScore(whole, in: Array(prepared.entry.path)) { return (.loose, score) }
            return nil
        }

        /// `composer` in `ChatComposer.swift`, or `list` in `chat-list.md`.
        private static func startsAWord(_ query: String, in name: String) -> Bool {
            let original = Array(name)
            let lowered = original.map { $0.lowercased().first ?? $0 }
            let query = Array(query)
            guard !query.isEmpty, query.count <= original.count else { return false }
            for index in 0...(original.count - query.count) where isWordStart(index, in: original) {
                if lowered[index..<(index + query.count)].elementsEqual(query) { return true }
            }
            return false
        }

        /// Each part starts a component, in order, skipping components as
        /// needed.
        private static func startsInOrder(_ parts: [String], _ components: ArraySlice<String>) -> Bool {
            var remaining = components[...]
            for part in parts {
                guard let index = remaining.firstIndex(where: { $0.hasPrefix(part) }) else { return false }
                remaining = remaining[(index + 1)...]
            }
            return true
        }

        /// fzf-style: the tightest window that holds the query as a
        /// subsequence, scored for runs, word starts and landing in the name.
        private static func subsequenceScore(_ query: [Character], in original: [Character]) -> Double? {
            let path = original.map { $0.lowercased().first ?? $0 }
            var queryIndex = 0
            var end = -1
            for (index, character) in path.enumerated() where character == query[queryIndex] {
                queryIndex += 1
                if queryIndex == query.count {
                    end = index
                    break
                }
            }
            guard end >= 0 else { return nil }

            var start = end
            queryIndex = query.count - 1
            while start >= 0 {
                if path[start] == query[queryIndex] {
                    if queryIndex == 0 { break }
                    queryIndex -= 1
                }
                start -= 1
            }

            let nameStart = (original.lastIndex(of: "/") ?? -1) + 1
            var score = 0.0
            var previousMatch = -2
            queryIndex = 0
            for index in start...end where queryIndex < query.count && path[index] == query[queryIndex] {
                score += 1
                if isWordStart(index, in: original) { score += 2 }
                if index == previousMatch + 1 { score += 2 }
                if index >= nameStart { score += 1 }
                previousMatch = index
                queryIndex += 1
            }
            score -= Double(end - start + 1 - query.count) * 0.1
            return score
        }

        private static func isWordStart(_ index: Int, in path: [Character]) -> Bool {
            guard index > 0 else { return true }
            let previous = path[index - 1]
            if "/_-. ".contains(previous) { return true }
            return path[index].isUppercase && previous.isLowercase
        }
    }
}
