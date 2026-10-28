import AppKit
import SwiftUI

struct CommandLineSettingsPane: View {
    @State private var settings = AppSettings.shared
    @State private var links: Links?
    @State private var isChangingLinks = false
    @State private var helperError: String?
    @State private var optInErrors: [CommandLineHelper.OptInCommand: String] = [:]
    @State private var zshrcURL: URL?
    @State private var zshrcHasInitLine = false
    @State private var zshrcError: String?
    /// Nil until the login shell's PATH is first read, since the line
    /// shown before then would not be the one tailored to it.
    @State private var initLine: String?
    @State private var loginPathDirectories: [String]?
    @State private var loginPathRead: Task<[String], Never>?

    private struct Links {
        var helper: CommandLineHelper.Summary
        var optIn: [CommandLineHelper.OptInCommand: CommandLineHelper.OptInSummary]

        nonisolated static func read() -> Links {
            var optIn: [CommandLineHelper.OptInCommand: CommandLineHelper.OptInSummary] = [:]
            for command in CommandLineHelper.OptInCommand.allCases {
                optIn[command] = CommandLineHelper.summary(of: CommandLineHelper.state(of: command), for: command)
            }
            return Links(helper: CommandLineHelper.summary(of: CommandLineHelper.states()), optIn: optIn)
        }
    }

    private enum Row: Equatable {
        case helper
        case optIn(CommandLineHelper.OptInCommand)
    }

    private var isToolOn: Bool { links?.helper.isOn ?? false }

    private func isOn(_ command: CommandLineHelper.OptInCommand) -> Bool {
        links?.optIn[command]?.isOn ?? false
    }

    private var zshrcDisplayPath: String {
        ZshrcSetup.displayPath(zshrcURL ?? ZshrcSetup.zshrcURL(zdotdir: nil))
    }

    private static var accent: Color { Color(nsColor: ThemeChrome.accentNSColor()) }

    var body: some View {
        Form {
            Section {
                commandLineToolRow
                if isToolOn {
                    ForEach(CommandLineHelper.OptInCommand.allCases, id: \.self) { command in
                        optInRow(command)
                    }
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
            await refresh(rereadingLoginPath: true)
        }
        // Returning from a terminal, where the user may have pasted the
        // line or linked a name by hand, activates the app and keys a window.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh(rereadingLoginPath: true) }
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

    private func optInRow(_ command: CommandLineHelper.OptInCommand) -> some View {
        let title: LocalizedStringKey = "`\(command.rawValue)` command"
        let summary = links?.optIn[command]
        let ids = Self.accessibilityIDs(command)
        return LabeledContent {
            VStack(alignment: .trailing) {
                Toggle(title, isOn: Binding(get: { isOn(command) }, set: { set(command, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .plumeID(
                        ids.toggle,
                        value: isOn(command) ? "on" : "off",
                        invoke: { set(command, on: !isOn(command)) }
                    )
                    .disabled(summary?.canToggle != true || isChangingLinks)
                if let note = summary?.note {
                    Text(note)
                        .foregroundStyle(.secondary)
                }
                if summary?.needsUpdate == true {
                    Button("Update") { set(command, on: true) }
                        .plumeID(ids.update, invoke: { set(command, on: true) })
                        .disabled(isChangingLinks)
                }
                if let error = optInErrors[command] {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            Text(title)
            Text("Links `\(command.rawValue)` into `~/.local/bin`, for agents and non-interactive terminals")
                .foregroundStyle(.secondary)
        }
    }

    private static func accessibilityIDs(_ command: CommandLineHelper.OptInCommand) -> (toggle: String, update: String) {
        switch command {
        case .wt: (AccessibilityID.settingsWTToggle, AccessibilityID.settingsWTUpdateButton)
        case .stack: (AccessibilityID.settingsStackToggle, AccessibilityID.settingsStackUpdateButton)
        }
    }

    private func set(_ command: CommandLineHelper.OptInCommand, on: Bool) {
        changeLinks(of: .optIn(command)) {
            if on { try CommandLineHelper.install(command) } else { try CommandLineHelper.uninstall(command) }
        }
    }

    private var shellSetupRow: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if let initLine {
                        Text(initLine)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading your shell's PATH…")
                            .foregroundStyle(.secondary)
                    }
                    Button(action: copyInitLine) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .tint(Self.accent)
                    .help("Copy")
                    .plumeID(AccessibilityID.settingsShellSetupCopyButton, invoke: copyInitLine)
                    .disabled(initLine == nil)
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
                        .disabled(zshrcURL == nil || initLine == nil)
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
        let availability = settings.nerdFontMode.iconAvailability
        return VStack(alignment: .trailing, spacing: 2) {
            statusLine("Plume and Ghostty", isOn: availability.plumeAndGhostty)
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

    /// The links publish first, because reading the login-shell PATH runs
    /// a shell that can take seconds. Only the pane appearing and the app
    /// becoming active reread it; a window becoming key reuses it.
    private func refresh(rereadingLoginPath: Bool = false) async {
        let url = zshrcURL
        let (links, hasInitLine) = await Task.detached { () -> (Links, Bool?) in
            (Links.read(), url.map(ZshrcSetup.isAdded(to:)))
        }.value
        self.links = links
        if let hasInitLine { zshrcHasInitLine = hasInitLine }

        let path: [String]
        if !rereadingLoginPath, let known = loginPathDirectories {
            path = known
        } else {
            path = await readLoginPath()
        }
        initLine = await Task.detached {
            ZshrcSetup.recommendedLine(executables: ZshrcSetup.executables(in: path))
        }.value
    }

    /// Joins a read already running, so overlapping refreshes start one shell.
    private func readLoginPath() async -> [String] {
        if let loginPathRead { return await loginPathRead.value }
        let read = Task.detached { LoginShellPath.directories() }
        loginPathRead = read
        let path = await read.value
        loginPathDirectories = path
        loginPathRead = nil
        return path
    }

    /// Runs a link change off the main actor, then rereads every link, since
    /// turning the tool off also removes the opt-in commands. The error lands
    /// beside the row that asked.
    private func changeLinks(of row: Row, _ change: @escaping @Sendable () throws -> Void) {
        guard !isChangingLinks else { return }
        isChangingLinks = true
        setError(nil, for: row)
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
            setError(error, for: row)
            if row == .helper, !links.helper.isOn { optInErrors = [:] }
            self.links = links
            isChangingLinks = false
        }
    }

    private func setError(_ error: String?, for row: Row) {
        switch row {
        case .helper: helperError = error
        case .optIn(let command): optInErrors[command] = error
        }
    }

    private func copyInitLine() {
        guard let initLine else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(initLine, forType: .string)
    }

    private func addInitLine() {
        guard let zshrcURL, let line = initLine else { return }
        zshrcError = nil
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try ZshrcSetup.add(to: zshrcURL, line: line)
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
