import AppKit
import SwiftUI

/// One reference in the draft shown as a chip: the whole token, trigger
/// included, and the icon drawn where its hidden trigger sits.
struct ComposerReferenceChip: Equatable {
    var range: NSRange
    var glyph: StatusGlyph
    var tint: NSColor
    var wash: NSColor
    var brand: ReferenceChipBrand?
    /// The token's link color, which the title and the brand logo share.
    var textTint: NSColor = .linkColor
    /// Drawn over the token with every character of it hidden, the way the
    /// chat shows a Linear issue's or a pull request's title. Nil shows the
    /// token's own text.
    var title: String?
    var toolTip: ToolTip?

    /// What the chip's tooltip names. Its text is read when the tooltip
    /// shows, so it carries whatever the stores have learned since.
    struct ToolTip: Equatable {
        var target: ReferenceTarget
        /// Shown until the stores know more.
        var fallback: ReferenceChipDetail?
        var title: String?
        var directory: String?

        @MainActor
        var text: String {
            var detail = fallback
            switch target {
            case .linear(let identifier):
                if let issue = LinearStore.shared.knownIssue(identifier: identifier) { detail = .linear(issue) }
            case .pullRequest:
                if let known = ReferenceChipStore.shared.detail(for: target) {
                    detail = known
                } else {
                    ReferenceChipStore.shared.lookUpDetail(of: target)
                }
            case .artifact, .file:
                break
            }
            return ReferenceChipTooltip.text(for: target, detail: detail, title: title, directory: directory)
        }
    }
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
        chips(
            for: MentionReference.references(in: text),
            caret: caret,
            palette: palette,
            textTint: textTint,
            resolution: resolution
        )
    }

    /// `references` as `MentionReference.references(in:)` finds them in the
    /// draft.
    @MainActor
    static func chips(
        for references: [MentionReference],
        caret: NSRange,
        palette: ReferenceChipPalette,
        textTint: NSColor = ThemeChrome.accentNSColor(),
        directory: String? = nil,
        resolution: (MentionReference.Kind) -> ResolvedMention?
    ) -> (chips: [ComposerReferenceChip], misses: [MentionReference.Kind]) {
        var chips: [ComposerReferenceChip] = []
        var misses: [MentionReference.Kind] = []
        let wash = NSColor(palette.accentWash)
        for reference in references {
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
                glyph: icon.glyph,
                tint: icon.tint == .link ? textTint : palette.nsColor(for: icon.tint),
                wash: wash,
                brand: reference.kind.brand,
                textTint: textTint,
                title: title(of: reference.kind, resolved),
                toolTip: toolTip(of: reference.kind, resolved, directory: directory)
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

    static func toolTip(of kind: MentionReference.Kind, _ resolved: ResolvedMention, directory: String?) -> ToolTip? {
        switch kind {
        case .linear(let identifier):
            return ToolTip(target: .linear(identifier: identifier.uppercased()), title: resolved.title)
        case .pullRequest(let number):
            guard let url = URL(string: resolved.target),
                  let target = ReferenceTarget.classify(url, base: nil),
                  case .pullRequest = target else { return nil }
            var fallback: ReferenceChipDetail?
            if case let .pullRequest(state, isDraft) = resolved.state {
                fallback = .pullRequest(.init(number: number, title: resolved.title ?? "", state: state, isDraft: isDraft))
            }
            return ToolTip(target: target, fallback: fallback, title: resolved.title)
        case .file:
            let path = resolved.target
            let absolute = path.hasPrefix("/") || directory == nil ? path : (directory! as NSString).appendingPathComponent(path)
            return ToolTip(target: .file(path: absolute), directory: directory)
        }
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

/// Registers a tooltip rect over each line of each composer chip, and answers
/// with the chip's text when AppKit asks for it.
@MainActor
final class ComposerReferenceToolTips: NSObject, NSViewToolTipOwner {
    private struct Region: Equatable {
        var rect: NSRect
        var toolTip: ComposerReferenceChip.ToolTip
    }

    private var regions: [Region] = []
    private var tags: [NSView.ToolTipTag] = []

    /// Re-registers only when a chip moved or changed, since this runs on
    /// every draw.
    func update(_ chips: [ComposerDecorations.ReferenceChip], in view: NSView) {
        let regions = chips.flatMap { chip in
            chip.toolTip.map { toolTip in chip.rects.map { Region(rect: $0, toolTip: toolTip) } } ?? []
        }
        guard regions != self.regions else { return }
        for tag in tags { view.removeToolTip(tag) }
        self.regions = regions
        tags = regions.indices.map { index in
            view.addToolTip(regions[index].rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    nonisolated func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        let index = Int(bitPattern: data) - 1
        return MainActor.assumeIsolated {
            regions.indices.contains(index) ? regions[index].toolTip.text : ""
        }
    }
}
