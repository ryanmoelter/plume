import Foundation

/// The user's extra `claude` arguments, from the setting's one-line string.
///
/// The string is split the way a POSIX shell splits words — quotes,
/// backslash escapes, and a leading `~` — but nothing is ever evaluated, so
/// `$VAR`, `$(…)`, `;` and globs reach `claude` literally.
///
/// Flags Plume's own launch depends on are dropped rather than passed. The
/// survivors go right after `claude`, ahead of Plume's flags, so a
/// single-valued flag Plume also sets (`--model`) resolves to Plume's value,
/// and a variadic one (`--add-dir`) can never swallow Plume's arguments.
nonisolated struct ClaudeExtraArguments: Equatable {
    enum ParseError: Error, Equatable {
        case unterminatedQuote
        case trailingBackslash
    }

    /// Flags that end in nothing usable, or desync Plume from the CLI it
    /// drives. Values are how many following words the flag consumes:
    /// `optional` takes the next word only when it isn't itself a flag.
    private enum Arity {
        case none
        case one
        case optional
    }

    private static let reserved: [String: Arity] = [
        "-p": .none, "--print": .none,
        "--output-format": .one, "--input-format": .one,
        "--permission-prompt-tool": .one,
        "--permission-mode": .one,
        "--dangerously-skip-permissions": .none,
        "--allow-dangerously-skip-permissions": .none,
        "--settings": .one,
        "-r": .optional, "--resume": .optional,
        "-c": .none, "--continue": .none,
        "--fork-session": .none, "--session-id": .one, "--resume-session-at": .one,
        "--bare": .none,
        "--bg": .none, "--background": .none,
        "--desktop": .none, "--cloud": .optional,
        "-h": .none, "--help": .none,
        "-v": .none, "--version": .none,
    ]

    private static let reservedShortLetters: Set<Character> = ["p", "r", "c", "h", "v"]

    /// What reaches `claude`, in order.
    let arguments: [String]
    /// The words dropped because Plume sets or forbids them, as typed.
    let ignored: [String]
    /// When the string cannot be split, nothing from it is passed at all.
    let parseError: ParseError?

    init(_ string: String, homeDirectory: String = NSHomeDirectory()) {
        do {
            let words = try Self.split(string, homeDirectory: homeDirectory)
            (arguments, ignored) = Self.filter(words)
            parseError = nil
        } catch {
            arguments = []
            ignored = []
            parseError = error
        }
    }

    static func split(_ string: String, homeDirectory: String = NSHomeDirectory()) throws(ParseError) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        // Tilde expands only when the word's first character is an unquoted `~`.
        var startsWithBareTilde = false
        var characters = Array(string)[...]

        func finishWord() {
            guard inWord else { return }
            if startsWithBareTilde, current == "~" || current.hasPrefix("~/") {
                current = homeDirectory + current.dropFirst()
            }
            words.append(current)
            current = ""
            inWord = false
            startsWithBareTilde = false
        }

        while let character = characters.popFirst() {
            switch character {
            case " ", "\t", "\n", "\r":
                finishWord()
            case "'":
                inWord = true
                guard let end = characters.firstIndex(of: "'") else { throw .unterminatedQuote }
                current.append(contentsOf: characters[..<end])
                characters = characters[characters.index(after: end)...]
            case "\"":
                inWord = true
                var closed = false
                while let inner = characters.popFirst() {
                    if inner == "\"" {
                        closed = true
                        break
                    }
                    if inner == "\\", let next = characters.first, "\"\\$`\n".contains(next) {
                        characters.removeFirst()
                        if next != "\n" { current.append(next) }
                    } else {
                        current.append(inner)
                    }
                }
                guard closed else { throw .unterminatedQuote }
            case "\\":
                guard let next = characters.popFirst() else { throw .trailingBackslash }
                // A backslash-newline is a line continuation, not a character.
                if next != "\n" {
                    inWord = true
                    current.append(next)
                }
            default:
                if !inWord, character == "~" { startsWithBareTilde = true }
                inWord = true
                current.append(character)
            }
        }
        finishWord()
        return words
    }

    private static func filter(_ words: [String]) -> (kept: [String], ignored: [String]) {
        var kept: [String] = []
        var ignored: [String] = []
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            index += 1
            if word == "--" {
                // Everything after `--` is a prompt, which Plume sends itself.
                ignored.append(contentsOf: words[(index - 1)...])
                break
            }
            if isReservedShortCluster(word) {
                ignored.append(word)
                continue
            }
            let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
            guard let arity = reserved[name] else {
                kept.append(word)
                continue
            }
            ignored.append(word)
            let hasInlineValue = name != word
            guard !hasInlineValue, index < words.endIndex else { continue }
            switch arity {
            case .none:
                break
            case .one:
                ignored.append(words[index])
                index += 1
            case .optional:
                if !words[index].hasPrefix("-") {
                    ignored.append(words[index])
                    index += 1
                }
            }
        }
        return (kept, ignored)
    }

    /// `-pc` and the like: combined short flags that include a reserved one.
    private static func isReservedShortCluster(_ word: String) -> Bool {
        guard word.count > 2, word.hasPrefix("-"), !word.hasPrefix("--") else { return false }
        let letters = word.dropFirst()
        return letters.allSatisfy { $0.isLetter } && letters.contains { reservedShortLetters.contains($0) }
    }
}
