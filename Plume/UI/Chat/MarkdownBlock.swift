import Foundation

/// A single block-level element of parsed markdown.
///
/// `AttributedString(markdown:)` handles inline formatting (bold, italic,
/// inline code, links) but has no notion of block structure — headings,
/// fenced code, lists, quotes. `parse(_:)` splits the raw text into blocks
/// by hand; `MarkdownView` then inline-parses each paragraph and list item.
///
/// Deliberately unsupported: nested lists and tables. A table's raw lines
/// fall through to `.paragraph` rather than being mangled or dropped.
nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case codeBlock(language: String?, code: String)
    case quote(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(trimmed) {
                let language = fence.language.isEmpty ? nil : fence.language
                var codeLines: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.token) {
                        break
                    }
                    codeLines.append(lines[cursor])
                    cursor += 1
                }
                // Unterminated fence: cursor ran off the end. Keep the
                // captured content instead of discarding it.
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                index = cursor + 1
                continue
            }

            if let level = headingLevel(trimmed) {
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    cursor += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                index = cursor
                continue
            }

            if bulletItemText(trimmed) != nil {
                var items: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard let item = bulletItemText(candidate) else { break }
                    items.append(item)
                    cursor += 1
                }
                blocks.append(.bulletList(items))
                index = cursor
                continue
            }

            if numberedItemText(trimmed) != nil {
                var items: [String] = []
                var cursor = index
                while cursor < lines.count {
                    let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard let item = numberedItemText(candidate) else { break }
                    items.append(item)
                    cursor += 1
                }
                blocks.append(.numberedList(items))
                index = cursor
                continue
            }

            // Paragraph: collect consecutive non-blank, non-block-marker lines.
            var paragraphLines: [String] = []
            var cursor = index
            while cursor < lines.count {
                let candidate = lines[cursor]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty
                    || fenceMarker(candidateTrimmed) != nil
                    || headingLevel(candidateTrimmed) != nil
                    || isRule(candidateTrimmed)
                    || candidateTrimmed.hasPrefix(">")
                    || bulletItemText(candidateTrimmed) != nil
                    || numberedItemText(candidateTrimmed) != nil {
                    break
                }
                paragraphLines.append(candidate)
                cursor += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            index = cursor
        }

        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> (token: String, language: String)? {
        for token in ["```", "~~~"] {
            if trimmed.hasPrefix(token) {
                let language = String(trimmed.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
                return (token, language)
            }
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        // Require a space (or end of line) after the hashes, else it's not a heading.
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return level
    }

    private static func isRule(_ trimmed: String) -> Bool {
        for marker: Character in ["-", "*", "_"] {
            let stripped = trimmed.filter { $0 == marker }
            if stripped.count >= 3 && stripped.count == trimmed.replacingOccurrences(of: " ", with: "").count {
                return true
            }
        }
        return false
    }

    private static func bulletItemText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static func numberedItemText(_ trimmed: String) -> String? {
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return nil }
        let afterDot = trimmed[trimmed.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return String(afterDot.dropFirst())
    }
}
