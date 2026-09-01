import Foundation

/// The JSON payload Claude Code pipes to a statusline command, captured
/// verbatim by `StatuslineCaptureWriter`'s generated script.
///
/// Only the fields Plume renders are decoded, all optional — `rate_limits` is
/// absent on non-Pro/Max sessions, and a new Claude Code field should never
/// break parsing. `~/.scripts/.claude/statusline.sh`'s `jq` call is the
/// authoritative shape reference.
struct StatuslinePayload: Decodable, Equatable {
    struct ContextWindow: Decodable, Equatable {
        let usedPercentage: Double?
        let totalInputTokens: Int?
        let totalOutputTokens: Int?
        let contextWindowSize: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case totalInputTokens = "total_input_tokens"
            case totalOutputTokens = "total_output_tokens"
            case contextWindowSize = "context_window_size"
        }
    }

    struct RateLimit: Decodable, Equatable {
        let usedPercentage: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    struct RateLimits: Decodable, Equatable {
        let fiveHour: RateLimit?
        let sevenDay: RateLimit?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    struct Cost: Decodable, Equatable {
        let totalCostUSD: Double?

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
        }
    }

    struct Workspace: Decodable, Equatable {
        let currentDir: String?

        enum CodingKeys: String, CodingKey {
            case currentDir = "current_dir"
        }
    }

    struct Model: Decodable, Equatable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    struct Effort: Decodable, Equatable {
        let level: String?
    }

    let contextWindow: ContextWindow?
    let rateLimits: RateLimits?
    let cost: Cost?
    let workspace: Workspace?
    let cwd: String?
    let model: Model?
    let effort: Effort?

    enum CodingKeys: String, CodingKey {
        case contextWindow = "context_window"
        case rateLimits = "rate_limits"
        case cost
        case workspace
        case cwd
        case model
        case effort
    }

    /// Total tokens counted toward the context window: input plus output.
    var contextUsedTokens: Int? {
        guard contextWindow?.totalInputTokens != nil || contextWindow?.totalOutputTokens != nil else {
            return nil
        }
        return (contextWindow?.totalInputTokens ?? 0) + (contextWindow?.totalOutputTokens ?? 0)
    }

    /// `workspace.current_dir`, falling back to `cwd` — the same fallback the
    /// shell script's `jq` filter uses for the branch lookup.
    var effectiveCwd: String? {
        workspace?.currentDir ?? cwd
    }
}
