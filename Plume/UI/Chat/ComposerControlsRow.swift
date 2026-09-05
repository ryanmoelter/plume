import SwiftUI

/// What the *next* message will do: where it runs (folder and worktree, on
/// the left) and how it runs (model, effort, permission mode, on the right).
/// The dropdowns read `HeadlessSession` state rather than the transcript.
/// Session-wide facts (quota, cost, branch) stay in `StatuslineStripView`;
/// these describe the turn about to be sent, so they live beside the send
/// button instead.
///
/// Each segment is self-contained — it reads and writes only its own piece of
/// session state — so the row can later become reorderable/hideable without
/// special-casing any one of them.
struct ComposerControlsRow: View, ThemedView {
    @Environment(\.theme) var theme

    @Bindable var task: WorkTask
    let headlessSession: HeadlessSession?
    /// False once an agent is running: the working directory is fixed at
    /// launch, so the workspace chips render as labels.
    var isWorkspaceEditable = true

    var body: some View {
        HStack(spacing: 12) {
            WorkspacePickerView(task: task, isEditable: isWorkspaceEditable)
                .accessibilityIdentifier(AccessibilityID.composerWorkspacePicker)
            Spacer(minLength: 8)
            if let headlessSession {
                ModelControl(session: headlessSession)
                EffortControl(session: headlessSession)
                PermissionModeControl(session: headlessSession)
            }
        }
        .font(typography.caption.font)
    }
}

/// A real dropdown — `.menuStyle(.borderlessButton)` supplies the one chevron
/// this label needs, so `segmentLabel` never draws its own.
private func segmentLabel(_ text: String, foreground: Color) -> some View {
    Text(text).foregroundStyle(foreground)
}

/// A mode this UI does not offer still shows its reported name — better a
/// truthful unfamiliar label than a familiar wrong one.
private struct PermissionModeControl: View, ThemedView {
    @Environment(\.theme) var theme
    @Bindable var session: HeadlessSession

    var body: some View {
        if let mode = session.permissionMode {
            Menu {
                ForEach(PermissionMode.allCases) { option in
                    Button(option.label) { session.setPermissionMode(option) }
                }
            } label: {
                segmentLabel(mode.label, foreground: foreground(for: attention(mode)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode")
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
    @Bindable var session: HeadlessSession

    var body: some View {
        if let model = session.model {
            Menu {
                ForEach(AgentModel.allCases) { option in
                    Button(option.label) { session.setModel(option) }
                }
            } label: {
                segmentLabel(model.label, foreground: colors.foreground)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")
            .accessibilityIdentifier(AccessibilityID.composerModelControl)
        }
    }
}

private struct EffortControl: View, ThemedView {
    @Environment(\.theme) var theme
    @Bindable var session: HeadlessSession

    var body: some View {
        Menu {
            ForEach(AgentEffort.allCases) { option in
                Button(option.label) { session.setEffort(option) }
            }
        } label: {
            // Nothing reports the CLI's own effort back (see `HeadlessSession.
            // setEffort`), so until this host sets one there is no value to
            // show. The control still renders — a value the user cannot see
            // is no reason to take away the only way to set it.
            segmentLabel(
                session.effort?.label ?? "Effort",
                foreground: session.effort.map { foreground(for: attention($0)) }
                    ?? colors.foreground.opacity(colors.emphasis[.secondary])
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

#Preview {
    ComposerControlsRow(
        task: WorkTask(title: "Preview", orderIndex: 0),
        headlessSession: nil
    )
    .padding()
}
