import AppKit
import SwiftUI

/// The sizes a reference chip is laid out with, shared by the chat and the
/// composer.
nonisolated struct ReferenceChipMetrics {
    let fontSize: CGFloat

    var iconSize: CGFloat { fontSize * 0.9 }
    var iconGap: CGFloat { fontSize * 0.25 }
    var padding: CGFloat { fontSize * 0.25 }
    var cornerRadius: CGFloat { 4 }
    /// Kern on the chat's placeholder, a narrow no-break space, so it holds
    /// the icon and the gap after it.
    var placeholderKern: CGFloat { fontSize * 0.95 }
    static let accentWash = 0.1
}

/// The colors a reference chip draws in, resolved for one appearance.
struct ReferenceChipPalette: Equatable {
    let neutral: Color
    let success: Color
    let danger: Color
    let merged: Color
    let accent: Color
    let codeFill: Color
    let linearStrategy: LinearStateColorStrategy
    private let palette: Palette

    @MainActor
    init(colors: Palette, colorScheme: ColorScheme, linearStrategy: LinearStateColorStrategy? = nil) {
        neutral = colors.surface(.secondary)
        success = colors.success
        danger = colors.danger
        merged = ChatRole.merged(for: colorScheme)
        accent = colors.selection
        codeFill = colors.surfaceTint
        self.linearStrategy = linearStrategy ?? AppSettings.shared.linearStateColors
        palette = colors
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.neutral == rhs.neutral && lhs.success == rhs.success && lhs.danger == rhs.danger
            && lhs.merged == rhs.merged && lhs.accent == rhs.accent && lhs.codeFill == rhs.codeFill
            && lhs.linearStrategy == rhs.linearStrategy
            && lhs.palette.backgroundRGB == rhs.palette.backgroundRGB
            && lhs.palette.foregroundRGB == rhs.palette.foregroundRGB
    }

    var accentWash: Color { accent.opacity(ReferenceChipMetrics.accentWash) }

    func color(for tint: ReferenceChipIcon.Tint) -> Color {
        switch tint {
        case .neutral: neutral
        case .success: success
        case .danger: danger
        case .merged: merged
        case .linear(let colorHex):
            LinearIssueGlyph.rgb(for: colorHex, strategy: linearStrategy, in: palette)
                .map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? neutral
        }
    }

    func nsColor(for tint: ReferenceChipIcon.Tint) -> NSColor {
        NSColor(color(for: tint))
    }
}
