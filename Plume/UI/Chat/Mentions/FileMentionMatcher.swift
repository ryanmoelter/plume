import Foundation

/// Ranks file and folder paths against a mention query: an exact name, then
/// a name prefix, then a prefix for each `/`-separated part in order, then a
/// subsequence of the whole path.
nonisolated enum FileMentionMatcher {
    static let defaultLimit = 20
    static let folderPenalty = 0.5

    static func matches(
        _ query: String,
        in entries: [MentionCandidate.FileEntry],
        limit: Int = defaultLimit
    ) -> [RankedMention] {
        let pattern = Pattern(query)
        let scored: [(quality: MentionMatchQuality, score: Double, entry: MentionCandidate.FileEntry)] =
            entries.compactMap { entry in
                guard let (quality, score) = pattern.match(entry.path) else { return nil }
                return (quality, entry.isDirectory ? score - folderPenalty : score, entry)
            }
        return scored
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.path.count != rhs.entry.path.count { return lhs.entry.path.count < rhs.entry.path.count }
                return lhs.entry.path < rhs.entry.path
            }
            .prefix(limit)
            .map { RankedMention(candidate: .file($0.entry), quality: $0.quality) }
    }

    private struct Pattern {
        let whole: [Character]
        /// The part being typed: what follows the last `/`.
        let name: String
        /// The parts before it, which must start the path's folders in order.
        let folders: [String]

        init(_ query: String) {
            var text = query.trimmingCharacters(in: .whitespaces).lowercased()
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

        func match(_ path: String) -> (MentionMatchQuality, Double)? {
            let lowered = path.lowercased()
            let components = lowered.split(separator: "/").map(String.init)
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
            if let score = Self.subsequenceScore(whole, in: Array(path)) { return (.loose, score) }
            return nil
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
