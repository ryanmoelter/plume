import SwiftUI

/// The type scale, derived from the user's chat font size.
///
/// Six roles on a 1.25 ratio: each step up is 25% larger than the one below
/// it, and `caption` sits one step below `body`. Views name a role rather
/// than multiplying the body size themselves, so the scale stays a scale.
///
/// Each role carries its face variants — `.mono` for code and identifiers,
/// `.semibold` and `.bold` for weight — so `design:` and `weight:` are not
/// written at call sites either.
struct Typography {
    /// Ratio between adjacent steps.
    static let ratio: CGFloat = 1.25

    /// Point size of `body`. Every other role is a power of `ratio` from here.
    let bodySize: CGFloat

    /// Which face this scale renders in. Code is always monospaced regardless.
    ///
    /// The system face is the app's voice — chrome, controls, what the user
    /// typed. Only the agent's own prose asks for the serif, through
    /// `inFace(_:)`.
    let proseFace: ChatProseFace

    init(bodySize: CGFloat, proseFace: ChatProseFace = .system) {
        self.bodySize = bodySize
        self.proseFace = proseFace
    }

    /// The same scale in a different face.
    func inFace(_ face: ChatProseFace) -> Typography {
        Typography(bodySize: bodySize, proseFace: face)
    }

    /// `bodySize` scaled by `ratio` to the given power. Negative steps down.
    func size(steps: Int) -> CGFloat {
        bodySize * pow(Self.ratio, CGFloat(steps))
    }

    // MARK: - Roles

    /// The largest heading: a document's own title. Markdown `h1`.
    var display: Style { style(steps: 4, weight: .bold, relativeTo: .largeTitle) }

    /// A major section. Markdown `h2`.
    var headline: Style { style(steps: 3, weight: .bold, relativeTo: .title) }

    /// A subsection. Markdown `h3`.
    var title: Style { style(steps: 2, weight: .bold, relativeTo: .title2) }

    /// Prose that wants to sit above the body — a lead paragraph, or a
    /// heading small enough to read as emphasis. Markdown `h4`.
    var bodyLarge: Style { style(steps: 1, weight: .semibold, relativeTo: .title3) }

    /// Prose. What the reader is here to read. Markdown `h5` takes this at
    /// semibold, since the ladder bottoms out before it.
    var body: Style { style(steps: 0, relativeTo: .body) }

    /// Everything supporting the prose: control labels, tool input and
    /// output, metadata, field keys, hints. Markdown `h6` at semibold.
    var caption: Style { style(steps: -1, relativeTo: .caption) }

    private func style(
        steps: Int,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle
    ) -> Style {
        Style(
            size: size(steps: steps),
            weight: weight,
            proseFace: proseFace,
            textStyle: textStyle
        )
    }

    /// A role's size, with the variants a call site might need.
    struct Style {
        let size: CGFloat
        let weight: Font.Weight
        let proseFace: ChatProseFace

        /// The text style this role's size is anchored to, so Dynamic Type
        /// scales it. Without an anchor a custom font is frozen at its point
        /// size and ignores the accessibility setting.
        let textStyle: Font.TextStyle

        /// The role as written — proportional, in the environment's face.
        var font: Font { face(weight: weight) }

        /// Extra leading between wrapped lines, on top of the font's own.
        /// Prose at reading measure needs more air than the default.
        var lineSpacing: CGFloat { size * 0.22 }

        var semibold: Font { face(weight: .semibold) }
        var bold: Font { face(weight: .bold) }
        var medium: Font { face(weight: .medium) }

        /// Monospaced, for code, paths and identifiers. Always the system
        /// mono face — the prose face has no monospaced variant.
        var mono: Font { monospaced(weight: weight) }

        var monoMedium: Font { monospaced(weight: .medium) }

        /// Monospaced only when `condition` holds, for rows that decide at
        /// runtime whether their content is code.
        func mono(when condition: Bool) -> Font {
            condition ? mono : font
        }

        private func face(weight: Font.Weight) -> Font {
            switch proseFace {
            case .serif:
                return .chatProse(size: size, weight: weight, relativeTo: textStyle)
            case .system:
                return .system(size: size, weight: weight)
            }
        }

        private func monospaced(weight: Font.Weight) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
