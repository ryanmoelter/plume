import AppKit
import SwiftUI
import Testing
@testable import Plume

#if DEBUG
/// Every `injectUsage` lands the state it asks for, whatever came before it,
/// and its reply reports that state. After `settle`, the control registry
/// reads it too, in a window that was never ordered on screen.
@MainActor
struct UsageInjectionTests {
    @MainActor private struct Harness {
        let settings: AppSettings
        let store = QuotaStore()
        let poller: ClaudeUsagePoller
        let cleanup: () -> Void

        init() throws {
            let suite = "UsageInjectionTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults, domainName: suite)
            poller = ClaudeUsagePoller(store: store, settings: settings, fetch: { _ in .failed })
            cleanup = { defaults.removePersistentDomain(forName: suite) }
        }

        func inject(_ params: InjectUsageParams) throws -> InjectUsageResult {
            try UsageInjection.apply(params, store: store, settings: settings, poller: poller)
        }
    }

    @Test func resendingTheSameValuesKeepsThem() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let params = InjectUsageParams(fable: 0.4, creditUsed: 12, creditLimit: 50)
        let first = try harness.inject(params)
        let second = try harness.inject(params)
        #expect(first == second)
        #expect(second.fable == 0.4)
        #expect(second.creditUsed == 12)
        #expect(second.shows == ["fable", "credit"])
    }

    @Test func aBareInjectClearsBothReadings() throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        _ = try harness.inject(InjectUsageParams(fable: 0.4, creditUsed: 12, creditLimit: 50))
        let cleared = try harness.inject(InjectUsageParams())
        #expect(cleared.fable == nil)
        #expect(cleared.creditUsed == nil)
        #expect(cleared.shows == [])
    }

    @Test func theRegistryReadsAnInjectionOnceSettled() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SidebarQuotaRow(quota: harness.store, settings: harness.settings, poller: harness.poller).frame(width: 240)
        )
        defer { window.close() }
        await UsageInjection.settle([window])
        let fable = {
            ControlRegistry.shared.entries(id: AccessibilityID.sidebarQuotaFable)
                .filter { $0.entry.window === window }
                .map { $0.entry.value ?? "" }
        }
        #expect(fable() == [])

        // The first inserts the glyph; the others change it in place.
        for (utilization, expected) in [(0.4, "40%"), (0.4, "40%"), (0.6, "60%")] {
            _ = try harness.inject(InjectUsageParams(fable: utilization))
            await UsageInjection.settle([window])
            #expect(fable() == [expected])
        }
    }
}
#endif
