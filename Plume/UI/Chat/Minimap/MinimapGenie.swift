import Foundation

/// The hover's local magnification: bars near the hovered row grow, falling
/// off smoothly to their resting size `radius` points away.
enum MinimapGenie {
    /// 1 at the hovered row, 0 at and beyond `radius`, with a raised-cosine
    /// falloff so neither end of the bump has a corner.
    static func influence(distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return distance == 0 ? 1 : 0 }
        let t = abs(distance) / radius
        guard t < 1 else { return 0 }
        return (1 + cos(.pi * t)) / 2
    }

    /// The factor a bar's size is multiplied by, from 1 at rest to
    /// `maximum` at the hovered row. `strength` fades the whole effect in
    /// and out as the pointer arrives and leaves.
    static func scale(distance: CGFloat, radius: CGFloat, maximum: CGFloat, strength: CGFloat = 1) -> CGFloat {
        1 + (maximum - 1) * influence(distance: distance, radius: radius) * min(max(strength, 0), 1)
    }
}
