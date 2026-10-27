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
    var brandTint: NSColor = .secondaryLabelColor
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
        resolution: (MentionReference.Kind) -> ResolvedMention?
    ) -> (chips: [ComposerReferenceChip], misses: [MentionReference.Kind]) {
        var chips: [ComposerReferenceChip] = []
        var misses: [MentionReference.Kind] = []
        let wash = NSColor(palette.accentWash)
        let brandTint = NSColor(palette.neutral)
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
                tint: palette.nsColor(for: icon.tint),
                wash: wash,
                brand: reference.kind.brand,
                brandTint: brandTint
            ))
        }
        return (chips, misses)
    }
}
