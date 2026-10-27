import AppKit
import SwiftUI

struct CommandLineSettingsPane: View {
    @State private var links: Links?
    @State private var isChangingLinks = false
    @State private var helperError: String?
    @State private var wtError: String?
    @State private var zshrcURL: URL?
    @State private var zshrcHasInitLine = false
    @State private var zshrcError: String?

    private struct Links {
        var helper: CommandLineHelper.Summary
        var wt: CommandLineHelper.WTSummary

        nonisolated static func read() -> Links {
            Links(
                helper: CommandLineHelper.summary(of: CommandLineHelper.states()),
                wt: CommandLineHelper.wtSummary(of: CommandLineHelper.wtState())
            )
        }
    }

    private enum Row { case helper, wt }

    private var isToolOn: Bool { links?.helper.isOn ?? false }

    var body: some View {
        Form {
            Section {
                commandLineToolRow
                if isToolOn {
                    wtLinkRow
                    shellSetupRow
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshLinks()
            let (url, added) = await Task.detached {
                let url = ZshrcSetup.resolveZshrcURL()
                return (url, ZshrcSetup.isAdded(to: url))
            }.value
            zshrcURL = url
            zshrcHasInitLine = added
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshLinks() }
        }
    }

    private var commandLineToolRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Toggle("Command line tool", isOn: toolBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .plumeID(
                        AccessibilityID.settingsCommandLineToolToggle,
                        value: isToolOn ? "on" : "off",
                        invoke: { setTool(on: !isToolOn) }
                    )
                    .disabled(links?.helper.canToggle != true || isChangingLinks)
                ForEach(links?.helper.notes ?? [], id: \.self) { note in
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if links?.helper.needsUpdate == true {
                    Button("Update") { changeLinks(of: .helper) { try CommandLineHelper.install() } }
                        .plumeID(
                            AccessibilityID.settingsCommandLineToolUpdateButton,
                            invoke: { changeLinks(of: .helper) { try CommandLineHelper.install() } }
                        )
                        .disabled(isChangingLinks)
                }
                if let helperError {
                    Text(helperError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Command line tool")
            Text("Links `plume` into `~/.local/bin`, for `plume notify`, `plume wt`, and more")
                .foregroundStyle(.secondary)
        }
    }

    private var toolBinding: Binding<Bool> {
        Binding(get: { isToolOn }, set: { setTool(on: $0) })
    }

    private func setTool(on: Bool) {
        changeLinks(of: .helper) {
            if on { try CommandLineHelper.install() } else { try CommandLineHelper.uninstall() }
        }
    }

    private var wtLinkRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                if let wt = links?.wt {
                    Text(wt.status)
                        .foregroundStyle(.secondary)
                        .plumeID(AccessibilityID.settingsWTLinkStatus, value: wt.status)
                    HStack {
                        if let installTitle = wt.installTitle {
                            Button(installTitle) { changeLinks(of: .wt) { try CommandLineHelper.installWT() } }
                                .plumeID(
                                    AccessibilityID.settingsWTLinkButton,
                                    invoke: { changeLinks(of: .wt) { try CommandLineHelper.installWT() } }
                                )
                                .disabled(isChangingLinks)
                        }
                        if wt.canRemove {
                            Button("Remove") { changeLinks(of: .wt) { try CommandLineHelper.uninstallWT() } }
                                .plumeID(
                                    AccessibilityID.settingsWTUnlinkButton,
                                    invoke: { changeLinks(of: .wt) { try CommandLineHelper.uninstallWT() } }
                                )
                                .disabled(isChangingLinks)
                        }
                    }
                }
                if let wtError {
                    Text(wtError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("`wt` command")
            Text("Also links `wt` into `~/.local/bin`, running `plume wt`")
                .foregroundStyle(.secondary)
        }
    }

    private var shellSetupRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(ZshrcSetup.initLine)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy", action: copyInitLine)
                        .plumeID(AccessibilityID.settingsShellSetupCopyButton, invoke: copyInitLine)
                    if zshrcHasInitLine {
                        Text("Added")
                            .foregroundStyle(.secondary)
                            .plumeID(AccessibilityID.settingsShellSetupStatus, value: "Added")
                    } else {
                        Button("Add to .zshrc", action: addInitLine)
                            .plumeID(AccessibilityID.settingsShellSetupAddButton, invoke: addInitLine)
                            .disabled(zshrcURL == nil)
                    }
                }
                if let zshrcURL, !zshrcHasInitLine {
                    Text("Appends to \((zshrcURL.path as NSString).abbreviatingWithTildeInPath)")
                        .foregroundStyle(.secondary)
                }
                if let zshrcError {
                    Text(zshrcError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Shell integration")
            Text("Completions, `wt`, and a `wt switch` that changes directory")
                .foregroundStyle(.secondary)
        }
    }

    private func refreshLinks() async {
        links = await Task.detached { Links.read() }.value
    }

    /// Runs a link change off the main actor, then rereads every link, since
    /// turning the tool off also removes `wt`. The error lands beside the row
    /// that asked.
    private func changeLinks(of row: Row, _ change: @escaping @Sendable () throws -> Void) {
        guard !isChangingLinks else { return }
        isChangingLinks = true
        let isHelperRow = row == .helper
        if isHelperRow { helperError = nil } else { wtError = nil }
        Task {
            let (error, links) = await Task.detached { () -> (String?, Links) in
                var message: String?
                do {
                    try change()
                } catch {
                    message = error.localizedDescription
                }
                return (message, Links.read())
            }.value
            if isHelperRow { helperError = error } else { wtError = error }
            if isHelperRow, !links.helper.isOn { wtError = nil }
            self.links = links
            isChangingLinks = false
        }
    }

    private func copyInitLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ZshrcSetup.initLine, forType: .string)
    }

    private func addInitLine() {
        guard let zshrcURL else { return }
        zshrcError = nil
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try ZshrcSetup.add(to: zshrcURL)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            zshrcError = error
            zshrcHasInitLine = error == nil
        }
    }
}
