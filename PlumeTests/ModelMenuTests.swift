import AppKit
import Testing
@testable import Plume

@MainActor struct ModelMenuTests {
    @Test(arguments: [Set<AgentProviderKind>(), [.claudeCode], [.codex]])
    func missingCLIsReplaceModelsWithDownloadLinks(installed: Set<AgentProviderKind>) throws {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let state = ComposerSettings(session: nil, tab: tab,
            defaults: .init(permissionMode: .auto, effort: .medium, model: .opus))
        var opened: [URL] = []
        let menu = ModelMenu.make(state: state, installed: installed, openURL: { opened.append($0) }) { _ in
            Issue.record("Missing CLI must not offer a custom model")
        }
        for (provider, model, download) in [(AgentProviderKind.claudeCode, "Opus", "Download Claude Code…"), (.codex, "Astra", "Download Codex…")] {
            #expect(menu.items.contains { $0.title == model } == installed.contains(provider))
            if !installed.contains(provider) {
                let index = try #require(menu.items.firstIndex { $0.title == download })
                menu.performActionForItem(at: index)
            }
        }
        #expect(opened.count == 2 - installed.count)
        #expect(opened.allSatisfy { $0.scheme == "https" })
        #expect(tab.provider == .claudeCode)
        #expect(tab.model == nil)
        #expect(menu.items.filter { $0.submenu != nil }.count == installed.count)
    }

    @Test func providerHeadersHaveVisibleLogosAndModelRowsHaveNone() throws {
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let state = ComposerSettings(session: nil, tab: tab,
            defaults: .init(permissionMode: .auto, effort: .medium, model: .opus))
        let menu = ModelMenu.make(state: state, installed: [.claudeCode, .codex]) { _ in }
        let headers = menu.items.filter(\.isSectionHeader)
        #expect(headers.map(\.title) == ["Claude", "Codex (Beta)"])
        for header in headers {
            let image = try #require(header.image)
            #expect(image.isValid)
            if #available(macOS 27.0, *) { #expect(header.preferredImageVisibility == .visible) }
        }
        #expect(menu.items.filter { !$0.isSectionHeader }.allSatisfy { $0.image == nil })
        let astra = try #require(menu.items.firstIndex { $0.title == "Astra" })
        menu.performActionForItem(at: astra)
        #expect(tab.provider == .codex)
        #expect(tab.model?.id == "gpt-6-astra")
        let claudeDefault = try #require(menu.items.firstIndex { $0.title == "Default (Opus)" })
        menu.performActionForItem(at: claudeDefault)
        #expect(tab.provider == .claudeCode)
        #expect(tab.model == nil)
    }
    @Test(arguments: [AgentProviderKind.claudeCode, .codex])
    func dismissalPersistsUntilCLIIsDetected(provider: AgentProviderKind) throws {
        let suite = "ModelMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let state = ComposerSettings(session: nil, tab: tab,
            defaults: .init(permissionMode: .auto, effort: .medium, model: .opus))
        let other: AgentProviderKind = provider == .codex ? .claudeCode : .codex
        let first = ModelMenu.make(state: state, installed: [other], settings: settings) { _ in }
        let dismiss = try #require(first.items.firstIndex { $0.title == "Dismiss" })
        first.performActionForItem(at: dismiss)
        #expect(settings.dismissedMissingProviders == [provider])
        let reloaded = AppSettings(defaults: defaults)
        let hidden = ModelMenu.make(state: state, installed: [other], settings: reloaded) { _ in }
        #expect(!hidden.items.contains { $0.title == AgentCLIInstallation.downloadTitle(for: provider) })
        #expect(hidden.items.filter(\.isSectionHeader).count == 1)
        #expect(!hidden.items.first!.isSeparatorItem)
        let installed = ModelMenu.make(state: state, installed: [.claudeCode, .codex], settings: reloaded) { _ in }
        #expect(installed.items.filter(\.isSectionHeader).count == 2)
        #expect(reloaded.dismissedMissingProviders.isEmpty)
        // A later uninstall restores the installation offer.
        let removed = ModelMenu.make(state: state, installed: [other], settings: reloaded) { _ in }
        #expect(removed.items.contains { $0.title == AgentCLIInstallation.downloadTitle(for: provider) })
    }

    @Test func dismissingBothProvidersKeepsSettingsReachable() throws {
        let suite = "ModelMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.dismissMissingProvider(.claudeCode)
        settings.dismissMissingProvider(.codex)
        let tab = TaskTab(kind: .agent, orderIndex: 0)
        let state = ComposerSettings(session: nil, tab: tab,
            defaults: .init(permissionMode: .auto, effort: .medium, model: .opus))
        var openedSettings = false
        let menu = ModelMenu.make(state: state, installed: [], settings: settings,
                                  onOpenSettings: { openedSettings = true }) { _ in }
        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "Install a CLI in Settings…")
        menu.performActionForItem(at: 0)
        #expect(openedSettings)
    }

}
