import AppKit
import SwiftUI

/// Keep native menu keyboard/navigation behavior, with explicit header image
/// visibility: macOS 27's automatic policy normally hides menu images.
struct ModelMenuButton: NSViewRepresentable {
    @Environment(\.openSettings) private var openSettings
    let state: ComposerSettings
    let label: String
    let onCustomModel: (AgentProviderKind) -> Void

    func makeNSView(context: Context) -> ModelPopupButton {
        let button = ModelPopupButton()
        button.isBordered = false
        button.title = ""
        button.target = button
        button.action = #selector(ModelPopupButton.showModels)
        return button
    }

    func updateNSView(_ button: ModelPopupButton, context: Context) {
        button.setAccessibilityLabel("Model")
        button.setAccessibilityValue(label)
        button.setAccessibilityIdentifier(AccessibilityID.composerModelControl)
        button.makeMenu = { installed in ModelMenu.make(state: state, installed: installed, onOpenSettings: { openSettings() }, onCustomModel: onCustomModel) }
    }
}

final class ModelPopupButton: NSButton {
    var makeMenu: ((Set<AgentProviderKind>) -> NSMenu)?
    private var checking = false
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    // The SwiftUI segment beneath this button supplies all its appearance.
    override func draw(_ dirtyRect: NSRect) {}

    @objc func showModels() {
        guard !checking else { return }
        checking = true
        Task { [weak self] in
            let installed = await Task.detached(priority: .userInitiated) {
                AgentCLIInstallation.installedProviders()
            }.value
            guard let self else { return }
            checking = false
            guard window != nil, let menu = makeMenu?(installed) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
        }
    }
}

@MainActor enum ModelMenu {
    static func make(state: ComposerSettings, installed: Set<AgentProviderKind>, settings: AppSettings? = nil, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }, onOpenSettings: @escaping () -> Void = {}, onCustomModel: @escaping (AgentProviderKind) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Model")
        menu.autoenablesItems = false
        let settings = settings ?? .shared
        settings.reconcileInstalledProviders(installed)
        let candidates: [AgentProviderKind] = state.canChangeProvider ? [.claudeCode, .codex] : [state.provider]
        let providers = candidates.filter { installed.contains($0) || !settings.dismissedMissingProviders.contains($0) }
        for (index, provider) in providers.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem.sectionHeader(title: provider == .claudeCode ? "Claude" : "Codex (Beta)")
            header.image = NSImage(named: provider.assetName)?.copy() as? NSImage
            header.image?.size = NSSize(width: 14, height: 14)
            header.image?.isTemplate = true
            if #available(macOS 27.0, *) { header.preferredImageVisibility = .visible }
            menu.addItem(header)

            guard installed.contains(provider) else {
                menu.addItem(ModelActionItem(title: AgentCLIInstallation.downloadTitle(for: provider)) {
                    openURL(AgentCLIInstallation.downloadURL(for: provider))
                })
                menu.addItem(ModelActionItem(title: "Dismiss") { settings.dismissMissingProvider(provider) })
                continue
            }
            let defaultTitle = state.defaultModel(for: provider).map { "Default (\($0.label))" } ?? "Default"
            menu.addItem(ModelActionItem(title: defaultTitle) { state.clearModel(for: provider) })
            let models = state.models(for: provider)
            for model in models.prefix(4) {
                menu.addItem(ModelActionItem(title: model.label) { state.setModel(model, provider: provider) })
            }
            let more = NSMenu(title: "More")
            more.autoenablesItems = false
            for model in models.dropFirst(4) {
                more.addItem(ModelActionItem(title: model.label) { state.setModel(model, provider: provider) })
            }
            if !more.items.isEmpty { more.addItem(.separator()) }
            more.addItem(ModelActionItem(title: "Other…") { onCustomModel(provider) })
            let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
            moreItem.submenu = more
            menu.addItem(moreItem)
        }
        if menu.items.isEmpty {
            menu.addItem(ModelActionItem(title: "Install a CLI in Settings…", perform: onOpenSettings))
        }
        return menu
    }
}

private final class ModelActionItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { perform() }
}
