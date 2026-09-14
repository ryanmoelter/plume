import AppKit

/// Copy and paste for the composer.
///
/// A copy writes two flavors: the visible plain text, so every other app sees
/// exactly the characters on screen, and a private type carrying the plume
/// attributes so a paste back into a composer keeps its formatting. Only the
/// attributes are archived — fonts, colors and paragraph styles are rebuilt
/// from the destination's `ComposerTextStyle`, so a slice copied at one chat
/// font size pastes at whatever size the destination composer is using.
nonisolated enum ComposerPasteboard {
    static let type = NSPasteboard.PasteboardType("com.ryanmoelter.Plume.composer-document")

    private struct Run: Codable {
        let text: String
        let block: ComposerBlockKind
        let inline: ComposerInlineStyle
        let link: URL?
    }

    static func data(from attributed: NSAttributedString) -> Data? {
        var runs: [Run] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            runs.append(Run(
                text: (attributed.string as NSString).substring(with: range),
                block: (attributes[.plumeBlock] as? ComposerBlockKind) ?? .paragraph,
                inline: (attributes[.plumeInline] as? ComposerInlineStyle) ?? [],
                link: attributes[.plumeLink] as? URL
            ))
        }
        return try? JSONEncoder().encode(runs)
    }

    static func attributedString(from data: Data, style: ComposerTextStyle) -> NSAttributedString? {
        guard let runs = try? JSONDecoder().decode([Run].self, from: data) else { return nil }
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(
                string: run.text,
                attributes: style.attributes(for: run.block, inline: run.inline, link: run.link)
            ))
        }
        return result.length > 0 ? result : nil
    }

    static func write(_ attributed: NSAttributedString, to pasteboard: NSPasteboard, type requested: NSPasteboard.PasteboardType) -> Bool {
        switch requested {
        case ComposerPasteboard.type:
            guard let data = data(from: attributed) else { return false }
            return pasteboard.setData(data, forType: ComposerPasteboard.type)
        case .string:
            return pasteboard.setString(attributed.string, forType: .string)
        default:
            return false
        }
    }

    static func read(from pasteboard: NSPasteboard, style: ComposerTextStyle) -> NSAttributedString? {
        guard let data = pasteboard.data(forType: ComposerPasteboard.type) else { return nil }
        return attributedString(from: data, style: style)
    }
}
