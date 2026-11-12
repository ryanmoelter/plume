import SwiftUI

/// A Linear workflow state as a symbol, colored by a
/// `LinearStateColorStrategy`.
struct LinearIssueGlyph: View, ThemedView {
    @Environment(\.theme) var theme

    let stateType: LinearStateType
    /// A `#rrggbb` hex string. An unparseable one, or a gray one under
    /// `.themePalette`, draws in the secondary text color.
    let colorHex: String?
    /// Nil draws Linear's color unchanged.
    let strategy: LinearStateColorStrategy?
    /// Only a `started` state reads it.
    let progress: LinearStartedProgress

    init(stateType: LinearStateType, progress: LinearStartedProgress, colorHex: String?) {
        self.init(
            stateType: stateType, progress: progress, colorHex: colorHex, strategy: AppSettings.shared.linearStateColors
        )
    }

    init(_ issue: LinearIssue) {
        self.init(stateType: issue.stateType, progress: issue.startedProgress, colorHex: issue.stateColor)
    }

    init(
        stateType: LinearStateType,
        progress: LinearStartedProgress,
        colorHex: String?,
        strategy: LinearStateColorStrategy?
    ) {
        self.stateType = stateType
        self.colorHex = colorHex
        self.strategy = strategy
        self.progress = progress
    }

    var body: some View {
        let image = StatusGlyphView(Self.glyph(for: stateType, progress: progress))
        if let color {
            image.foregroundStyle(color)
        } else {
            image.emphasis(.secondary)
        }
    }

    private var color: Color? {
        Self.rgb(for: colorHex, strategy: strategy, in: colors).map(Color.init)
    }

    /// Nil means the secondary text color.
    static func rgb(for colorHex: String?, strategy: LinearStateColorStrategy?, in colors: Palette) -> HexRGB? {
        guard let rgb = colorHex.flatMap(HexRGB.init(hex:)) else { return nil }
        switch strategy {
        case nil: return rgb
        case .themePalette:
            let candidates = LinearStateColor.candidates(in: colors, bright: false)
            return LinearStateColor.nearest(to: rgb, among: candidates).flatMap { candidates[$0] }
        case .ensureContrast:
            return LinearStateColor.contrasted(rgb, background: colors.backgroundRGB, foreground: colors.foregroundRGB)
        }
    }

    nonisolated static func glyph(for stateType: LinearStateType, progress: LinearStartedProgress) -> StatusGlyph {
        switch stateType {
        case .backlog: .symbol("circle.dashed")
        case .unstarted: .symbol("circle")
        case .started: .linearProgress(progress)
        case .completed: .symbol("checkmark.circle.fill")
        case .canceled: .symbol("xmark.circle.fill")
        case .duplicate: .symbol("equal.circle.fill")
        case .triage: .symbol("arrow.left.and.right.circle.fill")
        case .other: .symbol("circle")
        }
    }
}
