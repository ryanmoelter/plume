#if DEBUG
import AppKit
import SwiftUI

/// What `injectUsage` does to the stores, apart from the control server so a
/// test can run it against its own.
@MainActor
enum UsageInjection {
    static func apply(
        _ params: InjectUsageParams,
        store: QuotaStore,
        settings: AppSettings,
        poller: ClaudeUsagePoller,
        now: Date = Date()
    ) throws -> InjectUsageResult {
        try params.validate()
        // An animated insertion waits on the display cycle, which stops while
        // the display sleeps, so the row would show the old state.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            inject(params, store: store, poller: poller, now: now)
            if let alwaysShow = params.alwaysShow {
                settings.alwaysShowsCreditAndFableQuota = alwaysShow
            }
        }
        return InjectUsageResult(store.snapshot, settings: settings, now: store.now)
    }

    private static func inject(_ params: InjectUsageParams, store: QuotaStore, poller: ClaudeUsagePoller, now: Date) {
        guard params.hasReadings else {
            poller.endInjection()
            return
        }
        let cents = InjectUsageParams.cents
        let fable = params.fable.map { utilization in
            RateLimitInfo.Window(
                utilization: utilization,
                resetsAt: params.fableResetsInHours.map { now.addingTimeInterval($0 * 3600) }
            )
        }
        let hasCredit = params.creditUsed != nil || params.creditLimit != nil || params.creditBalance != nil
        let credit = hasCredit
            ? UsageCredit(
                usedCents: cents(params.creditUsed),
                limitCents: cents(params.creditLimit),
                balanceCents: cents(params.creditBalance),
                isEnabled: true,
                currency: "USD",
                resetsAt: params.creditResetsInDays.map { now.addingTimeInterval($0 * 86_400) }
            )
            : nil
        poller.isSuspended = true
        store.inject(
            fable: fable, credit: credit, isUsingOverage: params.isUsingOverage,
            clearsWindows: params.clearWindows == true, at: now
        )
    }

    /// Brings every window's SwiftUI content, and so the control registry,
    /// up to date with a state change without waiting on the display cycle.
    /// A control the change inserts registers from `onAppear`, which SwiftUI
    /// delivers on a main-queue turn after the layout that inserts it.
    static func settle(_ windows: [NSWindow]) async {
        let layout = { for window in windows { window.contentView?.layoutSubtreeIfNeeded() } }
        layout()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        layout()
    }
}

extension InjectUsageResult {
    init(_ snapshot: QuotaSnapshot?, settings: AppSettings, now: Date) {
        let dollars = { (cents: Int?) in cents.map { Double($0) / 100 } }
        let extras = SidebarQuotaExtras(snapshot: snapshot, alwaysShows: settings.alwaysShowsCreditAndFableQuota, now: now)
        var shows: [String] = []
        if extras.showsFable { shows.append("fable") }
        if extras.showsCredit { shows.append("credit") }
        self.init(
            fable: snapshot?.rateLimit.fable?.utilization,
            creditUsed: dollars(snapshot?.credit?.usedCents),
            creditLimit: dollars(snapshot?.credit?.limitCents),
            creditBalance: dollars(snapshot?.credit?.balanceCents),
            isUsingOverage: snapshot?.rateLimit.isUsingOverage ?? false,
            hasWindows: snapshot.map { $0.rateLimit.fiveHour != nil || $0.rateLimit.sevenDay != nil } ?? false,
            readsUsage: settings.readsClaudeUsage,
            alwaysShow: settings.alwaysShowsCreditAndFableQuota,
            shows: shows
        )
    }
}
#endif
