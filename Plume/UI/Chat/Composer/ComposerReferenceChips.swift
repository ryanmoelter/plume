import AppKit
import SwiftUI

/// One reference in the draft shown as a chip: the whole token, trigger
/// included, and the icon drawn where its hidden trigger sits.
struct ComposerReferenceChip: Equatable {
    var range: NSRange
    var symbol: String
    var tint: NSColor
    var wash: NSColor
    var brand: ReferenceChipBrand?
    /// The token's link color, which the title and the brand logo share.
    var textTint: NSColor = .linkColor
    /// Drawn over the token with every character of it hidden, the way the
    /// chat shows a Linear issue's or a pull request's title. Nil shows the
    /// token's own text.
    var title: String?
}

/// Where the composer learns what its references name: `MentionResolver`,
/// for one tab.
@MainActor
struct ComposerReferenceResolver: Equatable {
    let tabID: UUID
    let directory: String?
    var resolver: MentionResolver = .shared

    func cached(_ kind: MentionReference.Kind) -> ResolvedMention? {
        resolver.cachedResolution(of: kind, tabID: tabID)
    }

    func resolve(_ kind: MentionReference.Kind) async -> ResolvedMention? {
        await resolver.resolve(kind, tabID: tabID, directory: directory)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabID == rhs.tabID && lhs.directory == rhs.directory && lhs.resolver === rhs.resolver
    }
}

extension ComposerReferenceChip {
    /// The draft's references as chips, for those `resolution` knows. A
    /// reference the caret sits inside or just after is still being typed,
    /// so it stays plain text.
    @MainActor
    static func chips(
        in text: String,
        caret: NSRange,
        palette: ReferenceChipPalette,
        textTint: NSColor = ThemeChrome.accentNSColor(),
        resolution: (MentionReference.Kind) -> ResolvedMention?
    ) -> (chips: [ComposerReferenceChip], misses: [MentionReference.Kind]) {
        var chips: [ComposerReferenceChip] = []
        var misses: [MentionReference.Kind] = []
        let wash = NSColor(palette.accentWash)
        for reference in MentionReference.references(in: text) {
            let range = reference.range
            if caret.length == 0, caret.location > range.location, caret.location <= NSMaxRange(range) { continue }
            guard let resolved = resolution(reference.kind) else {
                misses.append(reference.kind)
                continue
            }
            let number: Int? = if case .pullRequest(let number) = reference.kind { number } else { nil }
            let icon = resolved.state.chipIcon(number: number)
            chips.append(ComposerReferenceChip(
                range: range,
                symbol: icon.symbol,
                tint: icon.tint == .link ? textTint : palette.nsColor(for: icon.tint),
                wash: wash,
                brand: reference.kind.brand,
                textTint: textTint,
                title: title(of: reference.kind, resolved)
            ))
        }
        return (chips, misses)
    }

    /// A file keeps its name; an issue or a pull request shows its title in
    /// place of its identifier, cut the way the chat cuts it.
    private static func title(of kind: MentionReference.Kind, _ resolved: ResolvedMention) -> String? {
        if case .file = kind { return nil }
        guard let title = resolved.title.map(ReferenceChipText.truncatedTitle), !title.isEmpty else { return nil }
        return title
    }

    /// The parts of `proposed` that land among a titled chip's hidden
    /// characters move to its nearer edge in the direction they moved, so a
    /// selection takes or leaves the chip whole. A caret is left alone: one
    /// inside a chip turns it back into text.
    static func snappedSelection(_ proposed: NSRange, previous: NSRange?, titledChips: [NSRange]) -> NSRange {
        guard proposed.length > 0, !titledChips.isEmpty else { return proposed }
        func snap(_ location: Int, from old: Int?, outward: (NSRange) -> Int) -> Int {
            guard let chip = titledChips.first(where: { location > $0.location && location < NSMaxRange($0) }) else {
                return location
            }
            guard let old, old != location else { return outward(chip) }
            return location > old ? NSMaxRange(chip) : chip.location
        }
        let start = snap(proposed.location, from: previous?.location) { $0.location }
        let end = snap(NSMaxRange(proposed), from: previous.map(NSMaxRange)) { NSMaxRange($0) }
        return NSRange(location: start, length: max(0, end - start))
    }
}
