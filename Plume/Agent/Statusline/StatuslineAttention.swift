import Foundation

/// The color a statusline metric should wear, matching
/// `~/.scripts/.claude/statusline.sh`'s `attn()`/`ctx_attn()` thresholds.
enum StatuslineAttention {
    case neutral
    case yellow
    case red

    /// General threshold: red at >=90%, yellow at >=70%.
    static func attention(percent: Double?) -> StatuslineAttention {
        let pct = percent ?? 0
        if pct >= 90 { return .red }
        if pct >= 70 { return .yellow }
        return .neutral
    }

    /// Context-window threshold: whichever bound trips first, so it adapts to
    /// window size — red at >=600k tokens or >=90%, yellow at >=300k or >=70%.
    static func attention(contextTokens: Int?, percent: Double?) -> StatuslineAttention {
        let tokens = contextTokens ?? 0
        let pct = percent ?? 0
        if tokens >= 600_000 || pct >= 90 { return .red }
        if tokens >= 300_000 || pct >= 70 { return .yellow }
        return .neutral
    }
}
