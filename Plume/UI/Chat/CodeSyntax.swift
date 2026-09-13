import Foundation

/// Syntax highlighting for fenced code blocks.
///
/// A hand-written tokenizer rather than a highlighter dependency. The
/// languages that actually appear in agent transcripts are a short list, and
/// the two obvious packages each miss most of it: Splash highlights Swift
/// alone, and Highlightr runs highlight.js in a JavaScript runtime, which is
/// a web stack's worth of binary for coloring text and does not suit the
/// statically linked single-binary release (`docs/releasing.md`).
///
/// Tokens name a *role*, not a color. `CodeSyntaxPalette` maps roles onto the
/// terminal theme's ANSI slots, so a block reads as part of the same surface
/// as the terminal beside it and follows light and dark without a second
/// palette.
///
/// The tokenizer is a single forward pass with no backtracking, so its cost
/// is linear in the code's length and it runs once per block through
/// `CodeSyntaxCache` — never per `body` pass. `docs/chat-list-hang.md` is why
/// nothing here may scale with render count or consult a measured height.
nonisolated enum CodeSyntax {
    /// What a token means. Deliberately coarse: more roles than a theme's
    /// palette can distinguish would collapse back to the same colors.
    enum Token: Equatable {
        /// Anything the language gives no special meaning.
        case plain
        case keyword
        case string
        case comment
        case number
        /// A type name, or a shell command in the command position.
        case type
    }

    /// One run of same-role characters, as a UTF-16 range for `NSRange` and
    /// `AttributedString` alike.
    struct Span: Equatable {
        var range: Range<Int>
        var token: Token
    }

    /// Spans for `code` under `language`'s grammar, in source order and
    /// covering only the non-plain runs.
    ///
    /// An unknown or absent language yields no spans, which renders as plain
    /// code — the common case, since most fences in real transcripts are
    /// untagged.
    static func spans(for code: String, language: String?) -> [Span] {
        guard let grammar = Grammar.named(language) else { return [] }
        return tokenize(Array(code.utf16), grammar: grammar)
    }

    /// A fence tag normalized for display, or nil when the fence carries no
    /// usable tag.
    ///
    /// A recognized alias resolves to its family's canonical spelling, so
    /// `objc` and `Objective-C` both read as `Objective-C`. A tag no grammar
    /// claims is still shown, trimmed and otherwise as the author typed it:
    /// it names the content even when nothing here can color it.
    static func displayName(for language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Grammar.displayNames[trimmed.lowercased()] ?? trimmed
    }

    // MARK: - Grammar

    /// The lexical rules of one language family.
    ///
    /// Families, not languages: `sh`, `bash` and `zsh` share every rule that
    /// matters at this resolution, and so do the C-like languages. Splitting
    /// them would multiply the table without changing a single color.
    struct Grammar {
        var keywords: Set<String>
        /// Words drawn as types. For shells these are the common commands,
        /// which occupy the same visual role: the thing being invoked.
        var types: Set<String>
        /// Line-comment openers, longest first so `///` wins over `//`.
        var lineComments: [String]
        /// Paired block-comment delimiters.
        var blockComments: [(open: String, close: String)]
        /// Quote characters that open a string.
        var quotes: Set<Character>
        /// Whether a backslash escapes the next character inside a string.
        var escapesInStrings: Bool
        /// Whether `#` opens a comment. Separate from `lineComments` only so
        /// a language that uses `#` for something else can say no.
        var highlightsNumbers: Bool

        /// The grammar for a fence tag, or nil when there is none to use.
        ///
        /// Tags arrive exactly as the author typed them, so matching folds
        /// case and tolerates the aliases that occur in practice.
        static func named(_ language: String?) -> Grammar? {
            guard let language else { return nil }
            let name = language
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !name.isEmpty else { return nil }
            return table[name]
        }

        private static let table: [String: Grammar] = {
            var table: [String: Grammar] = [:]
            for (names, grammar) in families {
                for name in names { table[name] = grammar }
            }
            return table
        }()

        /// The canonical spelling of each tag a fence may carry.
        ///
        /// Keyed by tag rather than by grammar family: a family groups
        /// languages that share lexical rules, so `cLike` covers Go, Rust and
        /// Java at once and has no one name to show.
        static let displayNames: [String: String] = {
            var names: [String: String] = [:]
            for (aliases, canonical) in spellings {
                for alias in aliases { names[alias] = canonical }
            }
            return names
        }()

        private static let spellings: [([String], String)] = [
            (["swift"], "Swift"),
            (["c", "h"], "C"),
            (["cpp", "c++", "cc", "hpp"], "C++"),
            (["objc", "objective-c", "m", "mm"], "Objective-C"),
            (["java"], "Java"),
            (["kotlin", "kt"], "Kotlin"),
            (["cs", "csharp"], "C#"),
            (["go"], "Go"),
            (["rust", "rs"], "Rust"),
            (["js", "javascript", "mjs", "cjs"], "JavaScript"),
            (["jsx"], "JSX"),
            (["ts", "typescript"], "TypeScript"),
            (["tsx"], "TSX"),
            (["py", "python", "python3"], "Python"),
            (["sh", "shell", "console", "shell-session"], "Shell"),
            (["bash"], "Bash"),
            (["zsh"], "Zsh"),
            (["fish"], "Fish"),
            (["rb", "ruby"], "Ruby"),
            (["json", "json5", "jsonc"], "JSON"),
            (["yaml", "yml"], "YAML"),
            (["toml"], "TOML"),
            (["ini"], "INI"),
            (["cfg", "conf"], "Config"),
            (["sql"], "SQL"),
            (["markdown", "md"], "Markdown"),
            (["html"], "HTML"),
            (["css"], "CSS"),
            (["xml"], "XML"),
            (["diff", "patch"], "Diff"),
            (["text", "txt", "plaintext"], "Text"),
        ]

        private static let families: [([String], Grammar)] = [
            (["swift"], .swift),
            (["c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "mm", "java", "kotlin", "kt", "cs", "csharp", "go", "rust", "rs"], .cLike),
            (["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"], .javaScript),
            (["py", "python", "python3"], .python),
            (["sh", "bash", "zsh", "shell", "console", "shell-session", "fish"], .shell),
            (["rb", "ruby"], .ruby),
            (["json", "json5", "jsonc"], .json),
            (["yaml", "yml"], .yaml),
            (["toml", "ini", "cfg", "conf"], .toml),
            (["sql"], .sql),
        ]

        static let swift = Grammar(
            keywords: [
                "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
                "class", "consuming", "continue", "default", "defer", "deinit", "do", "else",
                "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
                "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "lazy",
                "let", "mutating", "nil", "nonisolated", "open", "operator", "private", "protocol",
                "public", "repeat", "required", "rethrows", "return", "self", "Self", "some",
                "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
                "typealias", "var", "weak", "where", "while", "willSet", "didSet", "get", "set",
                "unowned", "package", "borrowing", "consume", "each", "macro",
            ],
            types: [
                "Any", "AnyObject", "Array", "Bool", "CGFloat", "Character", "Data", "Date",
                "Dictionary", "Double", "Error", "Float", "Int", "Never", "Optional", "Result",
                "Set", "String", "Task", "UInt", "URL", "UUID", "Void",
            ],
            lineComments: ["///", "//"],
            blockComments: [("/*", "*/")],
            quotes: ["\""],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let cLike = Grammar(
            keywords: [
                "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue",
                "default", "defer", "delete", "do", "double", "else", "enum", "export", "extern",
                "false", "final", "float", "for", "func", "fun", "go", "goto", "if", "impl",
                "import", "in", "inline", "int", "interface", "let", "long", "match", "mut",
                "namespace", "new", "nil", "null", "nullptr", "override", "package", "private",
                "protected", "public", "range", "return", "self", "short", "signed", "sizeof",
                "static", "struct", "super", "switch", "template", "this", "throw", "true", "try",
                "type", "typedef", "typename", "union", "unsigned", "use", "using", "val", "var",
                "virtual", "void", "volatile", "where", "while", "yield", "fn", "pub", "crate",
                "@interface", "@implementation", "@end", "@property", "@synthesize", "@selector",
            ],
            types: [
                "BOOL", "Bool", "Double", "Float", "Int", "Integer", "NSArray", "NSDictionary",
                "NSError", "NSObject", "NSString", "Object", "String", "bool", "int8", "int16",
                "int32", "int64", "uint8", "uint16", "uint32", "uint64", "usize", "isize",
            ],
            lineComments: ["///", "//"],
            blockComments: [("/*", "*/")],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let javaScript = Grammar(
            keywords: [
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false",
                "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
                "instanceof", "interface", "let", "new", "null", "of", "private", "protected",
                "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw",
                "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield",
            ],
            types: [
                "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number", "Object",
                "Promise", "RegExp", "Set", "String", "Symbol", "any", "boolean", "console",
                "never", "number", "string", "unknown", "window",
            ],
            lineComments: ["//"],
            blockComments: [("/*", "*/")],
            quotes: ["\"", "'", "`"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let python = Grammar(
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
                "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise", "return",
                "self", "True", "False", "try", "while", "with", "yield", "case",
            ],
            types: [
                "bool", "bytes", "dict", "float", "frozenset", "int", "list", "object", "print",
                "set", "str", "tuple", "type", "Any", "Dict", "List", "Optional", "Sequence", "Tuple",
            ],
            lineComments: ["#"],
            blockComments: [],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let shell = Grammar(
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
                "esac", "in", "function", "select", "time", "return", "break", "continue", "local",
                "export", "readonly", "declare", "unset", "shift", "source", "alias", "set",
            ],
            types: [
                "awk", "bash", "cat", "cd", "chmod", "cp", "curl", "cut", "date", "diff", "echo",
                "env", "find", "git", "grep", "head", "kill", "less", "ln", "ls", "make", "mkdir",
                "mv", "npm", "open", "pgrep", "printf", "ps", "pwd", "python", "python3", "read",
                "rm", "sed", "sleep", "sort", "ssh", "sudo", "swift", "tail", "tar", "tee", "test",
                "touch",
                "tr", "uniq", "wc", "wget", "which", "xargs", "xcodebuild", "yarn", "zsh",
            ],
            lineComments: ["#"],
            blockComments: [],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: false
        )

        static let ruby = Grammar(
            keywords: [
                "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
                "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
                "unless", "until", "when", "while", "yield", "require", "attr_accessor",
            ],
            types: ["Array", "Hash", "Integer", "Float", "String", "Symbol", "Struct", "Proc"],
            lineComments: ["#"],
            blockComments: [],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let json = Grammar(
            keywords: ["true", "false", "null"],
            types: [],
            lineComments: [],
            blockComments: [],
            quotes: ["\""],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let yaml = Grammar(
            keywords: ["true", "false", "null", "yes", "no", "on", "off", "~"],
            types: [],
            lineComments: ["#"],
            blockComments: [],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let toml = Grammar(
            keywords: ["true", "false"],
            types: [],
            lineComments: ["#", ";"],
            blockComments: [],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )

        static let sql = Grammar(
            keywords: [
                "add", "all", "alter", "and", "as", "asc", "between", "by", "case", "column",
                "create", "delete", "desc", "distinct", "drop", "else", "end", "exists", "from",
                "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join",
                "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer",
                "primary", "right", "select", "set", "table", "then", "union", "update", "values",
                "view", "when", "where", "with",
            ],
            types: ["bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "float",
                    "int", "integer", "numeric", "real", "text", "timestamp", "varchar"],
            lineComments: ["--"],
            blockComments: [("/*", "*/")],
            quotes: ["\"", "'"],
            escapesInStrings: true,
            highlightsNumbers: true
        )
    }

    // MARK: - Tokenizer

    /// One forward pass over the UTF-16 units.
    ///
    /// UTF-16 because the spans address an `AttributedString`, and a
    /// `Character`-indexed range would have to be converted anyway. Adjacent
    /// spans of the same role are merged so the styling walk stays short.
    private static func tokenize(_ units: [UInt16], grammar: Grammar) -> [Span] {
        var spans: [Span] = []
        var index = 0

        func append(_ range: Range<Int>, _ token: Token) {
            guard !range.isEmpty else { return }
            if var last = spans.last, last.token == token, last.range.upperBound == range.lowerBound {
                last.range = last.range.lowerBound ..< range.upperBound
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(range: range, token: token))
            }
        }

        while index < units.count {
            let start = index

            if let end = commentEnd(units, from: index, grammar: grammar) {
                append(start ..< end, .comment)
                index = end
                continue
            }

            if let character = ascii(units[index]), grammar.quotes.contains(character) {
                let end = stringEnd(units, from: index, quote: units[index], grammar: grammar)
                append(start ..< end, .string)
                index = end
                continue
            }

            if isWordStart(units[index]) {
                var end = index + 1
                while end < units.count, isWordBody(units[end]) { end += 1 }
                let word = String(decoding: units[start ..< end], as: UTF16.self)
                if grammar.keywords.contains(word) {
                    append(start ..< end, .keyword)
                } else if grammar.types.contains(word) {
                    append(start ..< end, .type)
                }
                index = end
                continue
            }

            if grammar.highlightsNumbers, isDigit(units[index]) {
                var end = index + 1
                while end < units.count, isNumberBody(units[end]) { end += 1 }
                append(start ..< end, .number)
                index = end
                continue
            }

            index += 1
        }

        return spans
    }

    /// The end of the comment opening at `index`, or nil if none opens there.
    ///
    /// An unterminated block comment runs to the end of the code, which is
    /// what an editor shows for the same text.
    private static func commentEnd(_ units: [UInt16], from index: Int, grammar: Grammar) -> Int? {
        for opener in grammar.lineComments where matches(units, at: index, opener) {
            var end = index
            while end < units.count, units[end] != newline { end += 1 }
            return end
        }
        for (open, close) in grammar.blockComments where matches(units, at: index, open) {
            var end = index + open.utf16.count
            while end < units.count {
                if matches(units, at: end, close) { return end + close.utf16.count }
                end += 1
            }
            return units.count
        }
        return nil
    }

    /// The end of the string literal opening at `index`, past its closing
    /// quote. An unterminated literal stops at the line break rather than
    /// swallowing the rest of the block — a lone apostrophe in a shell
    /// comment is far more common than a genuine multi-line literal.
    private static func stringEnd(
        _ units: [UInt16],
        from index: Int,
        quote: UInt16,
        grammar: Grammar
    ) -> Int {
        var end = index + 1
        while end < units.count {
            let unit = units[end]
            if unit == newline { return end }
            if grammar.escapesInStrings, unit == backslash, end + 1 < units.count {
                end += 2
                continue
            }
            end += 1
            if unit == quote { return end }
        }
        return units.count
    }

    private static func matches(_ units: [UInt16], at index: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf16)
        guard index + pattern.count <= units.count else { return false }
        for offset in 0 ..< pattern.count where units[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static let newline: UInt16 = 10
    private static let backslash: UInt16 = 92

    private static func ascii(_ unit: UInt16) -> Character? {
        guard unit < 128, let scalar = Unicode.Scalar(unit) else { return nil }
        return Character(scalar)
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    /// Hex digits, exponents and separators all continue a number, so `0xFF`
    /// and `1_000.5e3` each colour as one token.
    private static func isNumberBody(_ unit: UInt16) -> Bool {
        isDigit(unit) || isLetter(unit) || unit == 46 || unit == 95
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    /// `@` starts a word so Objective-C's `@interface` and Swift's attributes
    /// match as written.
    private static func isWordStart(_ unit: UInt16) -> Bool {
        isLetter(unit) || unit == 95 || unit == 64
    }

    private static func isWordBody(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == 95 || unit == 63
    }
}
