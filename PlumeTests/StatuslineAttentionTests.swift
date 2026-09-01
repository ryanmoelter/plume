import Testing
@testable import Plume

struct StatuslineAttentionTests {
    @Test func percentBoundaries() {
        #expect(StatuslineAttention.attention(percent: 0) == .neutral)
        #expect(StatuslineAttention.attention(percent: 69) == .neutral)
        #expect(StatuslineAttention.attention(percent: 70) == .yellow)
        #expect(StatuslineAttention.attention(percent: 89) == .yellow)
        #expect(StatuslineAttention.attention(percent: 90) == .red)
        #expect(StatuslineAttention.attention(percent: 100) == .red)
    }

    @Test func percentTreatsNilAsZero() {
        #expect(StatuslineAttention.attention(percent: nil) == .neutral)
    }

    @Test func contextTokenBoundaries() {
        #expect(StatuslineAttention.attention(contextTokens: 299_999, percent: 0) == .neutral)
        #expect(StatuslineAttention.attention(contextTokens: 300_000, percent: 0) == .yellow)
        #expect(StatuslineAttention.attention(contextTokens: 599_999, percent: 0) == .yellow)
        #expect(StatuslineAttention.attention(contextTokens: 600_000, percent: 0) == .red)
    }

    @Test func contextPercentBoundariesTripIndependentlyOfTokens() {
        #expect(StatuslineAttention.attention(contextTokens: 0, percent: 69) == .neutral)
        #expect(StatuslineAttention.attention(contextTokens: 0, percent: 70) == .yellow)
        #expect(StatuslineAttention.attention(contextTokens: 0, percent: 89) == .yellow)
        #expect(StatuslineAttention.attention(contextTokens: 0, percent: 90) == .red)
    }

    @Test func contextWhicheverBoundTripsFirstWins() {
        // Low percent but huge window (e.g. 1M context) still needs attention.
        #expect(StatuslineAttention.attention(contextTokens: 600_000, percent: 10) == .red)
        #expect(StatuslineAttention.attention(contextTokens: 300_000, percent: 10) == .yellow)
        // High percent but tiny absolute usage still needs attention.
        #expect(StatuslineAttention.attention(contextTokens: 100, percent: 90) == .red)
    }

    @Test func contextTreatsNilAsZero() {
        #expect(StatuslineAttention.attention(contextTokens: nil, percent: nil) == .neutral)
    }
}
