import AppKit
import SwiftUI

/// What the *next* message will do: where it runs (folder and worktree, on
/// the left) and how it runs (model, effort, permission mode, on the right).
/// The dropdowns read `HeadlessSession` state rather than the transcript.
/// Session-wide facts (quota, cost, branch) stay in `StatuslineStripView`;
/// these describe the turn about to be sent, so they live beside the send
/// button instead.
///
/// Before a session exists the same three controls read and write the tab's
/// own persisted values, which is what `AgentLauncher` launches from — so the
/// first turn, the only one whose settings are free to choose, is settable
/// too. Once launched the session's live values take over.
///
/// Each segment is self-contained — it reads and writes only its own piece of
/// session state — so the row can later become reorderable/hideable without
/// special-casing any one of them.
struct ComposerControlsRow: View, ThemedView {
    @Environment(\.theme) var theme

    @Bindable var task: WorkTask
    @Bindable var tab: TaskTab
    let headlessSession: HeadlessSession?
    /// False once an agent is running: the working directory is fixed at
    /// launch, so the workspace chips render as labels.
    var isWorkspaceEditable = true

    var body: some View {
        HStack(spacing: dimensions.panelContentInset) {
            WorkspacePickerView(task: task, isEditable: isWorkspaceEditable)
                .accessibilityIdentifier(AccessibilityID.composerWorkspacePicker)
            Spacer(minLength: dimensions.panelContentInset)
            if let headlessSession {
                RemoteControlControl(session: headlessSession)
            }
            ModelControl(state: settings)
            EffortControl(state: settings)
            PermissionModeControl(state: settings)
        }
        .font(typography.caption.font)
        // The row sits level with the send and stop circles beside it, so
        // every segment takes their height rather than its own text's.
        .frame(minHeight: dimensions.composerControlHeight)
    }

    private var settings: ComposerSettings {
        ComposerSettings(
            session: headlessSession,
            tab: tab,
            defaults: .resolved(task: task)
        )
    }
}

/// A real dropdown — `.menuStyle(.borderlessButton)` supplies the one chevron
/// this label needs, so `segmentLabel` never draws its own.
private func segmentLabel(_ text: String, foreground: Color, height: CGFloat) -> some View {
    Text(text)
        .foregroundStyle(foreground)
        .frame(height: height)
}

/// A mode this UI does not offer still shows its reported name — better a
/// truthful unfamiliar label than a familiar wrong one.
private struct PermissionModeControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings

    var body: some View {
        if let mode = state.permissionMode {
            Menu {
                ForEach(PermissionMode.allCases) { option in
                    Button(option.label) { state.setPermissionMode(option) }
                }
            } label: {
                segmentLabel(
                    mode.label,
                    foreground: foreground(for: attention(mode)),
                    height: dimensions.composerControlHeight
                )
                .unconfirmed(state.isModeAndModelUnconfirmed)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(state.modeAndModelHelp("Permission mode"))
            .accessibilityIdentifier(AccessibilityID.composerPermissionModeControl)
        }
    }

    /// Bypassing every permission check is worth flagging; the rest are
    /// ordinary working modes.
    private func attention(_ mode: PermissionMode) -> StatuslineAttention {
        mode == .bypassPermissions ? .red : .neutral
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        StatuslineColors.foreground(for: attention, colors: colors)
    }
}

private struct ModelControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings

    @State private var isAskingForCustomID = false
    @State private var customID = ""

    var body: some View {
        Menu {
            if let resolved = state.defaultModel {
                Button("Default (\(resolved.label))") { state.clearModel() }
                Divider()
            }
            ForEach([AgentModel.fable, .opus, .sonnet, .haiku]) { option in
                Button(option.label) { state.setModel(option) }
            }
            Menu("More") {
                ForEach(AgentModel.more) { option in
                    Button(option.label) { state.setModel(option) }
                }
                Divider()
                Button("Other…") { isAskingForCustomID = true }
            }
        } label: {
            segmentLabel(label, foreground: colors.foreground, height: dimensions.composerControlHeight)
                .unconfirmed(state.isModelAwaitingConfirmation)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(state.modeAndModelHelp("Model"))
        .accessibilityIdentifier(AccessibilityID.composerModelControl)
        .popover(isPresented: $isAskingForCustomID) {
            CustomModelIDField(id: $customID) {
                state.setModel(AgentModel(unrecognizedID: $0))
            }
        }
    }

    /// A tab that has never chosen one launches without `--model` and runs on
    /// the CLI's configured model, so the label names that rather than going
    /// blank — and marks it a default, since nothing has been pinned.
    private var label: String {
        guard let model = state.model else { return "Model" }
        return state.isModelDefaulted ? "Default (\(model.label))" : model.label
    }
}

/// Takes a model ID the menu has no item for. Free text, because the CLI
/// accepts any ID its backend knows and this build's list is only a snapshot.
private struct CustomModelIDField: View {
    @Binding var id: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model ID").font(.caption)
            TextField("claude-…", text: $id)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use", action: submit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func submit() {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (try? ModelEffortCommand.sanitizedToken(trimmed)) != nil else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

private struct EffortControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings

    var body: some View {
        Menu {
            ForEach(AgentEffort.allCases) { option in
                Button(option.label) { state.setEffort(option) }
            }
        } label: {
            // Nothing reports the CLI's own effort back (see `HeadlessSession.
            // setEffort`), so an untouched tab shows the app default, which is
            // also what seeds the session.
            segmentLabel(
                state.effort.label,
                foreground: foreground(for: attention(state.effort)),
                height: dimensions.composerControlHeight
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Changing effort has no control request, so it sends an ordinary
        // chat turn — that turn appearing in the transcript is expected.
        .help("Effort (sends a message to change)")
        .accessibilityIdentifier(AccessibilityID.composerEffortControl)
    }

    /// Matches `statusline.sh`'s `effort_seg`: `xhigh`/`max` need attention.
    private func attention(_ level: AgentEffort) -> StatuslineAttention {
        switch level {
        case .xhigh, .max: return .yellow
        default: return .neutral
        }
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        StatuslineColors.foreground(for: attention, colors: colors)
    }
}

/// Remote Control's own segment, driving the same `setRemoteControl` the
/// typed `/rc` does. Absent before a session exists, since there is no bridge
/// to attach to until then.
private struct RemoteControlControl: View, ThemedView {
    @Environment(\.theme) var theme
    let session: HeadlessSession

    var body: some View {
        Menu {
            switch session.remoteControl {
            case .connected(let link):
                Button("Disconnect") { session.setRemoteControl(enabled: false) }
                if let url = link.shareableURL {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
            default:
                Button("Connect") { session.setRemoteControl(enabled: true) }
            }
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(height: dimensions.composerControlHeight)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Remote Control")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(AccessibilityID.composerRemoteControlControl)
    }

    private var symbol: String {
        switch session.remoteControl {
        case .connected, .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected, .failed: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    /// `attention` is the palette's blue, taken from the terminal theme like
    /// every other status hue, so this reads as part of the same surface.
    private var tint: Color {
        switch session.remoteControl {
        case .failed: return colors.danger
        case .connected: return colors.attention
        case .connecting: return colors.attention.opacity(colors.emphasis[.secondary])
        case .disconnected: return colors.foreground.opacity(colors.emphasis[.secondary])
        }
    }

    private var accessibilityValue: String {
        switch session.remoteControl {
        case .disconnected: return "Off"
        case .connecting: return "Connecting"
        case .connected: return "On"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var helpText: String {
        switch session.remoteControl {
        case .connected: return "Remote Control is on \u{2014} this session is on claude.ai/code"
        case .connecting: return "Connecting to Remote Control\u{2026}"
        case .failed(let message): return "Remote Control failed: \(message)"
        case .disconnected: return "Remote Control \u{2014} drive this session from your phone or claude.ai/code"
        }
    }
}

private extension View {
    /// Dims a label whose value is Plume's own guess rather than something the
    /// conversation has reported.
    func unconfirmed(_ isUnconfirmed: Bool) -> some View {
        opacity(isUnconfirmed ? 0.55 : 1)
    }
}

#Preview {
    ComposerControlsRow(
        task: WorkTask(title: "Preview", orderIndex: 0),
        tab: TaskTab(kind: .agent, orderIndex: 0),
        headlessSession: nil
    )
    .padding()
}
