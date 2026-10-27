import AppKit
import SwiftUI

/// The sizes a reference chip is laid out with, shared by the chat and the
/// composer.
nonisolated struct ReferenceChipMetrics {
    let fontSize: CGFloat

    var iconSize: CGFloat { fontSize * 0.9 }
    var iconGap: CGFloat { fontSize * 0.25 }
    var brandGap: CGFloat { fontSize * 0.2 }
    var padding: CGFloat { fontSize * 0.25 }
    var cornerRadius: CGFloat { 4 }
    static let accentWash = 0.1
    /// A filled logo reads heavier than an outlined symbol of the same size.
    static let brandScale = 0.8

    /// What a brand logo adds in front of the status icon.
    func brandWidth(_ brand: ReferenceChipBrand?) -> CGFloat {
        brand == nil ? 0 : iconSize + brandGap
    }

    /// Kern on the chat's placeholder, a narrow no-break space, so it holds
    /// the icons and the gap after them.
    func placeholderKern(brand: ReferenceChipBrand?) -> CGFloat {
        fontSize * 0.95 + brandWidth(brand)
    }

    /// Kern on the composer's hidden trigger, which is set in a 1 pt font.
    func triggerKern(brand: ReferenceChipBrand?) -> CGFloat {
        brandWidth(brand) + iconSize + iconGap
    }

    struct IconRects: Equatable {
        var brand: CGRect?
        var status: CGRect
    }

    /// The icon squares from `leadingX`, centered on the chip's own midpoint
    /// rather than on the text's baseline.
    func iconRects(leadingX: CGFloat, chipMidY: CGFloat, brand: ReferenceChipBrand?) -> IconRects {
        let minY = chipMidY - iconSize / 2
        return IconRects(
            brand: brand.map { _ in CGRect(x: leadingX, y: minY, width: iconSize, height: iconSize) },
            status: CGRect(x: leadingX + brandWidth(brand), y: minY, width: iconSize, height: iconSize)
        )
    }
}

/// The service a reference chip names, shown as its logo before the status
/// icon.
nonisolated enum ReferenceChipBrand: Hashable, Sendable {
    case github
    case linear

    var imageName: String {
        switch self {
        case .github: "GitHubMark"
        case .linear: "LinearLogo"
        }
    }
}

extension ReferenceTarget {
    nonisolated var brand: ReferenceChipBrand? {
        switch self {
        case .linear: .linear
        case .pullRequest: .github
        case .file: nil
        }
    }
}

extension MentionReference.Kind {
    nonisolated var brand: ReferenceChipBrand? {
        switch self {
        case .linear: .linear
        case .pullRequest: .github
        case .file: nil
        }
    }
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
