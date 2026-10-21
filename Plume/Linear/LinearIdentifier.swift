import Foundation

/// Finds and validates Linear issue identifiers such as `PLUME-102`.
nonisolated enum LinearIdentifier {
    private static let maxKeyLength = 7

    /// Every `KEY-123` in a branch name, uppercased and de-duplicated, in order.
    /// The key must start at the string start or after a non-alphanumeric, so
    /// `abcplume-1` yields nothing, and the number must be all digits.
    static func candidates(inBranch branch: String) -> [String] {
        var tokens: [(text: Substring, dashBefore: Bool)] = []
        var start: String.Index?
        var previousEnd: String.Index?
        var dashBefore = false
        let chars = branch
        var index = chars.startIndex
        func close(at end: String.Index) {
            guard let s = start else { return }
            tokens.append((chars[s..<end], dashBefore))
            start = nil
            previousEnd = end
        }
        while index < chars.endIndex {
            let c = chars[index]
            if c.isASCII, c.isLetter || c.isNumber {
                if start == nil {
                    start = index
                    dashBefore = previousEnd.map { chars[$0..<index] == "-" } ?? false
                }
            } else {
                close(at: index)
            }
            index = chars.index(after: index)
        }
        close(at: chars.endIndex)

        var result: [String] = []
        for i in 1..<max(tokens.count, 1) where tokens[i].dashBefore {
            let key = tokens[i - 1].text
            let number = tokens[i].text
            guard isKey(key), number.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let identifier = "\(key.uppercased())-\(number)"
            if !result.contains(identifier) { result.append(identifier) }
        }
        return result
    }

    static func filter(_ candidates: [String], teamKeys: Set<String>) -> [String] {
        candidates.filter { teamKeys.contains(teamKey(of: $0)) }
    }

    /// Validates one identifier, or a pasted Linear issue URL, and returns it
    /// uppercased. Returns nil for anything else.
    static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if let range = trimmed.range(of: "/issue/", options: .caseInsensitive) {
            candidate = String(trimmed[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        return parse(candidate)
    }

    static func teamKey(of identifier: String) -> String {
        identifier.uppercased().prefix { $0 != "-" }.description
    }

    private static func isKey(_ text: Substring) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter else { return false }
        return text.count <= maxKeyLength
    }

    private static func parse(_ text: String) -> String? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, isKey(parts[0]), !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return "\(parts[0].uppercased())-\(parts[1])"
    }
}
