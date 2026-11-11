#if DEBUG
import SwiftUI

/// A row of boxes, one per order of magnitude a file's changed lines reach,
/// each larger than the last.
nonisolated enum ReviewChangeMagnitude {
    /// How much larger each box is than the one before it.
    static let growth: CGFloat = 1.5
    /// The side of the 100-line box, which anchors the scale.
    static let baseSize: CGFloat = 8
    private static let anchorIndex = 2

    /// 0 for no lines, 1 for 1–9, 2 for 10–99, and so on.
    static func boxCount(changedLines: Int) -> Int {
        var count = 0
        var threshold = 1
        while changedLines >= threshold {
            count += 1
            guard threshold <= Int.max / 10 else { break }
            threshold *= 10
        }
        return count
    }

    static func side(ofBox index: Int) -> CGFloat {
        baseSize * pow(growth, CGFloat(index - anchorIndex))
    }

    /// Mostly added reads as added, mostly removed as deleted, and anything
    /// between as modified, where mostly is two thirds of the lines.
    static func tint(added: Int, removed: Int) -> DiffChangeKind {
        if added >= removed * 2 { return .added }
        if removed >= added * 2 { return .deleted }
        return .modified
    }
}

struct ReviewChangeMagnitudeView: View, ThemedView {
    @Environment(\.theme) var theme
    let file: DiffFileSummary

    var body: some View {
        let changed = file.addedLines + file.removedLines
        let count = ReviewChangeMagnitude.boxCount(changedLines: changed)
        if count > 0 {
            let kind = ReviewChangeMagnitude.tint(added: file.addedLines, removed: file.removedLines)
            let color = ReviewChangeBadge.color(for: kind, in: colors)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    let side = ReviewChangeMagnitude.side(ofBox: index)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: side, height: side)
                }
            }
            .help(changed == 1 ? "1 changed line" : "\(changed) changed lines")
        }
    }
}
#endif
