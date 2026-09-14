import AppKit
import Foundation

/// The custom attribute vocabulary the composer's `NSTextStorage` carries.
///
/// `NSTextStorage` is the model in the WYSIWYG composer: these three keys are
/// how block structure (heading, list, code, ...), inline style (bold,
/// italic, code), and links survive alongside AppKit's own attributes.
nonisolated extension NSAttributedString.Key {
    /// The `ComposerBlockKind` a paragraph belongs to.
    static let plumeBlock = NSAttributedString.Key("plumeBlock")
    /// The `ComposerInlineStyle` a run carries.
    static let plumeInline = NSAttributedString.Key("plumeInline")
    /// The `URL` a linked run points to.
    static let plumeLink = NSAttributedString.Key("plumeLink")
}

/// The block-level kind of one composer paragraph, stored under
/// `.plumeBlock` across the paragraph's full range (content and its
/// trailing newline alike).
///
/// `blockID` distinguishes adjacent `codeBlock` or `verbatim` paragraphs
/// that would otherwise compare equal: two fenced blocks back to back, both
/// unlabeled or both the same language, and two thematic breaks in a row,
/// must still serialize as two blocks rather than one merged block. Every
/// other kind forces `blockID` to a shared sentinel in `init`, so two
/// paragraphs of the same kind always compare equal regardless of what a
/// caller happened to pass — nothing needs to know to thread a shared id
/// through for headings, quotes, or list items.
nonisolated struct ComposerBlockKind: Hashable, Sendable, Codable {
    enum Kind: Hashable, Sendable, Codable {
        case paragraph
        case heading(level: Int)
        case bullet(depth: Int)
        case numbered(depth: Int, number: Int)
        case quote
        case codeBlock(language: String?)
        /// An unsupported construct (a table, a rule, ...) whose lines are
        /// kept as literal text rather than modeled structurally.
        case verbatim
    }

    let kind: Kind
    let blockID: UUID

    private static let sharedBlockID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    init(_ kind: Kind, blockID: UUID = UUID()) {
        self.kind = kind
        switch kind {
        case .codeBlock, .verbatim:
            self.blockID = blockID
        default:
            self.blockID = ComposerBlockKind.sharedBlockID
        }
    }

    static let paragraph = ComposerBlockKind(.paragraph)
    static let quote = ComposerBlockKind(.quote)

    static func heading(_ level: Int) -> ComposerBlockKind {
        ComposerBlockKind(.heading(level: level))
    }

    static func bullet(depth: Int) -> ComposerBlockKind {
        ComposerBlockKind(.bullet(depth: depth))
    }

    static func numbered(depth: Int, number: Int) -> ComposerBlockKind {
        ComposerBlockKind(.numbered(depth: depth, number: number))
    }

    static func codeBlock(language: String?, blockID: UUID = UUID()) -> ComposerBlockKind {
        ComposerBlockKind(.codeBlock(language: language), blockID: blockID)
    }

    static func verbatim(blockID: UUID = UUID()) -> ComposerBlockKind {
        ComposerBlockKind(.verbatim, blockID: blockID)
    }

    /// Whether `blockID` distinguishes this kind from an identical neighbor,
    /// which is what makes two adjacent blocks of it stay two blocks.
    var hasOwnBlockID: Bool {
        switch kind {
        case .codeBlock, .verbatim: true
        default: false
        }
    }

    var isList: Bool {
        switch kind {
        case .bullet, .numbered: true
        default: false
        }
    }

    var depth: Int {
        switch kind {
        case let .bullet(depth): depth
        case let .numbered(depth, _): depth
        default: 0
        }
    }
}

/// The inline style a run carries, stored under `.plumeInline`.
///
/// `code` wins over `bold`/`italic` when resolving a font (see
/// `ComposerTextStyle.font(for:inline:)`), but the bits themselves aren't
/// mutually exclusive — a run can carry more than one and let the resolver
/// decide precedence.
nonisolated struct ComposerInlineStyle: OptionSet, Hashable, Sendable, Codable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let bold = ComposerInlineStyle(rawValue: 1 << 0)
    static let italic = ComposerInlineStyle(rawValue: 1 << 1)
    static let code = ComposerInlineStyle(rawValue: 1 << 2)
}
