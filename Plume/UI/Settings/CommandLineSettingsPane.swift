import AppKit
import SwiftUI

struct CommandLineSettingsPane: View {
    @State private var settings = AppSettings.shared
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
    private var isWTOn: Bool { links?.wt.isOn ?? false }

    private var zshrcDisplayPath: String {
        ZshrcSetup.displayPath(zshrcURL ?? ZshrcSetup.zshrcURL(zdotdir: nil))
    }

    private static var accent: Color { Color(nsColor: ThemeChrome.accentNSColor()) }

    var body: some View {
        Form {
            Section {
                commandLineToolRow
                if isToolOn {
                    wtRow
                    shellSetupRow
                }
            } header: {
                Text("Installation")
            }

            Section {
                nerdFontPicker
                nerdFontStatus
                NerdFontPreview()
            } header: {
                Text("Customization")
            }
        }
        .formStyle(.grouped)
        .task {
            let url = await Task.detached { ZshrcSetup.resolveZshrcURL() }.value
            zshrcURL = url
            await refresh()
        }
        // Returning from a terminal, where the user may have pasted the
        // line or linked a name by hand, activates the app and keys a window.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var commandLineToolRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Toggle("Command line tool", isOn: Binding(get: { isToolOn }, set: { setTool(on: $0) }))
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
            Text("Links `plume` into `~/.local/bin`")
                .foregroundStyle(.secondary)
        }
    }

    private func setTool(on: Bool) {
        changeLinks(of: .helper) {
            if on { try CommandLineHelper.install() } else { try CommandLineHelper.uninstall() }
        }
    }

    private var wtRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Toggle("`wt` command", isOn: Binding(get: { isWTOn }, set: { setWT(on: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .plumeID(
                        AccessibilityID.settingsWTToggle,
                        value: isWTOn ? "on" : "off",
                        invoke: { setWT(on: !isWTOn) }
                    )
                    .disabled(links?.wt.canToggle != true || isChangingLinks)
                if let note = links?.wt.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if links?.wt.needsUpdate == true {
                    Button("Update") { changeLinks(of: .wt) { try CommandLineHelper.installWT() } }
                        .plumeID(
                            AccessibilityID.settingsWTUpdateButton,
                            invoke: { changeLinks(of: .wt) { try CommandLineHelper.installWT() } }
                        )
                        .disabled(isChangingLinks)
                }
                if let wtError {
                    Text(wtError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("`wt` command")
            Text("Links `wt` into `~/.local/bin`, for agents and non-interactive terminals")
                .foregroundStyle(.secondary)
        }
    }

    private func setWT(on: Bool) {
        changeLinks(of: .wt) {
            if on { try CommandLineHelper.installWT() } else { try CommandLineHelper.uninstallWT() }
        }
    }

    private var shellSetupRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    Text(ZshrcSetup.initLine)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button(action: copyInitLine) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .tint(Self.accent)
                    .help("Copy")
                    .plumeID(AccessibilityID.settingsShellSetupCopyButton, invoke: copyInitLine)
                }
                if zshrcHasInitLine {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("in \(zshrcDisplayPath)")
                    }
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.settingsShellSetupStatus, value: "in \(zshrcDisplayPath)")
                } else {
                    Button("Append to \(zshrcDisplayPath)", action: addInitLine)
                        .plumeID(AccessibilityID.settingsShellSetupAddButton, invoke: addInitLine)
                        .disabled(zshrcURL == nil)
                }
                if let zshrcError {
                    Text(zshrcError)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text("Shell integration")
            Text("Completions and `wt switch` support")
                .foregroundStyle(.secondary)
        }
    }

    private var nerdFontPicker: some View {
        Picker(selection: $settings.nerdFontMode) {
            ForEach(NerdFontMode.allCases, id: \.self) { mode in
                Text(Self.name(mode)).tag(mode)
            }
        } label: {
            Text("Nerd Font icons")
        }
        .plumeID(AccessibilityID.settingsNerdFontPicker, value: settings.nerdFontMode.rawValue)
    }

    private var nerdFontStatus: some View {
        let availability = settings.nerdFontMode.iconAvailability(
            hasCustomTerminalFont: GhosttyRuntime.shared.resolvedCodeFontFamily != nil
        )
        return VStack(alignment: .trailing, spacing: 2) {
            statusLine("Plume terminals", isOn: availability.plumeTerminals)
            statusLine("Other terminals", isOn: availability.otherTerminals)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func statusLine(_ title: String, isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: isOn ? "checkmark" : "xmark")
        }
        .plumeID(AccessibilityID.settingsNerdFontStatus, label: title, value: isOn ? "yes" : "no")
    }

    private static func name(_ mode: NerdFontMode) -> String {
        switch mode {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }

    private func refresh() async {
        let url = zshrcURL
        let (links, hasInitLine) = await Task.detached {
            (Links.read(), url.map(ZshrcSetup.isAdded(to:)))
        }.value
        self.links = links
        if let hasInitLine { zshrcHasInitLine = hasInitLine }
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

/// The glyphs a `wt list` row can print, in each glyph set, painted in the
/// terminal theme's own colors on its background, so the choice can be made
/// by eye.
private struct NerdFontPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ThemeChrome.terminalColors(for: colorScheme)
        let nerd = TerminalUI(glyphSet: .nerd).listGlyphSlots
        let plain = TerminalUI(glyphSet: .plain).listGlyphSlots
        Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 4) {
            row("Nerd Font", nerd, colors)
            row("Plain", plain, colors)
        }
        .font(Self.font)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(
        _ title: String,
        _ glyphs: [(glyph: String, color: TerminalColor)],
        _ colors: ThemeChrome.TerminalColors
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(Self.color(.dim, colors))
                .gridColumnAlignment(.leading)
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(glyph.glyph.isEmpty ? " " : glyph.glyph)
                    .foregroundStyle(Self.color(glyph.color, colors))
                    .frame(minWidth: 16)
            }
        }
    }

    private static var font: Font {
        BundledFonts.isCodeAvailable ? .custom(BundledFonts.code, size: 13) : .system(size: 13, design: .monospaced)
    }

    /// Dim text is the foreground at ghostty's default `faint-opacity`.
    private static func color(_ color: TerminalColor, _ colors: ThemeChrome.TerminalColors) -> Color {
        switch color {
        case .foreground: colors.foreground
        case .dim: colors.foreground.opacity(0.5)
        case .red: colors.palette[1]
        case .green: colors.palette[2]
        case .yellow: colors.palette[3]
        case .magenta: colors.palette[5]
        }
    }
}
