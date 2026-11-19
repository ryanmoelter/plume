import AppKit
import SwiftUI
import Testing
@testable import Plume

/// The statusline collapses in three steps as it narrows: side-by-side
/// meters with the Fable and credit glyphs, then stacked bars with the
/// glyphs, then stacked bars alone. Each step is narrower than the last, and
/// `StatuslineStages` picks the first that fits.
@MainActor
struct StatuslineStageTests {
    private final class Chosen {
        var stage: StatuslineStage?
    }

    @MainActor private struct Harness {
        let settings: AppSettings
        let store: QuotaStore
        let poller: ClaudeUsagePoller
        let cleanup: () -> Void

        init() throws {
            let suite = "StatuslineStageTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults, domainName: suite)
            let now = Date()
            store = QuotaStore(now: now)
            store.record(
                RateLimitInfo(
                    fiveHour: .init(utilization: 0.5, resetsAt: now.addingTimeInterval(3600)),
                    sevenDay: .init(utilization: 0.3, resetsAt: now.addingTimeInterval(86400)),
                    isUsingOverage: false
                ),
                at: now
            )
            store.record(
                ClaudeUsageReading(
                    fable: .init(utilization: 0.4, resetsAt: now.addingTimeInterval(86400)),
                    credit: UsageCredit(usedCents: 1_000, limitCents: 5_000)
                ),
                at: now
            )
            poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in .failed })
            cleanup = { defaults.removePersistentDomain(forName: suite) }
        }

        func strip(_ stage: StatuslineStage, provider: AgentProviderKind = .claudeCode) -> StatuslineStripView {
            StatuslineStripView(
                layout: stage.meters,
                provider: provider,
                showsQuotaGlyphs: stage.showsQuotaGlyphs,
                contextUsedTokens: 50_000,
                contextMaxTokens: 200_000,
                quota: store,
                settings: settings,
                poller: poller
            )
        }
    }

    private func idealWidth(_ view: some View) -> CGFloat {
        NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width
    }

    private func chosenStage(_ harness: Harness, width: CGFloat) -> StatuslineStage? {
        let chosen = Chosen()
        let stages = StatuslineStages { stage in
            harness.strip(stage)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in chosen.stage = stage }
        }
        let host = NSHostingView(rootView: stages.frame(width: width, alignment: .trailing))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 60)
        host.layoutSubtreeIfNeeded()
        return chosen.stage
    }

    @Test func eachStageIsNarrowerThanTheOneBefore() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let wide = idealWidth(harness.strip(.wide))
        let stacked = idealWidth(harness.strip(.stacked))
        let bare = idealWidth(harness.strip(.stackedWithoutGlyphs))
        #expect(wide > stacked, "wide \(wide), stacked \(stacked)")
        #expect(stacked > bare, "stacked \(stacked), without glyphs \(bare)")
    }

    @Test func theRowPicksTheWidestStageThatFits() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let wide = idealWidth(harness.strip(.wide))
        let stacked = idealWidth(harness.strip(.stacked))
        let bare = idealWidth(harness.strip(.stackedWithoutGlyphs))

        #expect(chosenStage(harness, width: wide) == .wide)
        #expect(chosenStage(harness, width: wide - 1) == .stacked)
        #expect(chosenStage(harness, width: stacked) == .stacked)
        #expect(chosenStage(harness, width: stacked - 1) == .stackedWithoutGlyphs)
        #expect(chosenStage(harness, width: bare) == .stackedWithoutGlyphs)
    }

    @Test func creditJoinsTheStackedPopoverOnceItsGlyphIsDropped() {
        let now = Date()
        var snapshot = QuotaSnapshot.empty(at: now)
        snapshot.credit = UsageCredit(usedCents: 1_000, limitCents: 5_000)
        let extras = SidebarQuotaExtras(snapshot: snapshot, alwaysShows: false, now: now)
        #expect(StatuslineStripView.showsCreditInPopover(showsQuotaGlyphs: false, extras: extras))
        #expect(!StatuslineStripView.showsCreditInPopover(showsQuotaGlyphs: true, extras: extras), "the glyph already shows it")
        #expect(!StatuslineStripView.showsCreditInPopover(showsQuotaGlyphs: false, extras: nil), "a Codex strip has no credit")

        snapshot.credit = UsageCredit(usedCents: 1_000, limitCents: nil)
        let noLimit = SidebarQuotaExtras(snapshot: snapshot, alwaysShows: true, now: now)
        #expect(!StatuslineStripView.showsCreditInPopover(showsQuotaGlyphs: false, extras: noLimit))
    }

    @Test func theStackedPopoverDrawsTheCreditSection() {
        let popover = { (showsCredit: Bool) in
            StatuslineUsagePopover(
                contextUsedTokens: 50_000,
                contextMaxTokens: 200_000,
                quotaSummaries: [],
                showsCredit: showsCredit,
                credit: UsageCredit(usedCents: 1_000, limitCents: 5_000),
                headlessSession: nil
            )
        }
        let height = { (view: StatuslineUsagePopover) in
            NSHostingController(rootView: view.frame(width: 260)).sizeThatFits(in: CGSize(width: 260, height: 10_000)).height
        }
        #expect(height(popover(true)) > height(popover(false)) + 40, "used, limit and left are three lines plus a meter")
    }

    @Test func aCodexStripHasNoGlyphsToDrop() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let stacked = idealWidth(harness.strip(.stacked, provider: .codex))
        let bare = idealWidth(harness.strip(.stackedWithoutGlyphs, provider: .codex))
        #expect(stacked == bare)
    }
}
