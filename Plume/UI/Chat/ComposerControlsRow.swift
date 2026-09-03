import SwiftUI

/// What the *next* message will do: permission mode, model, effort — all
/// interactive, all read from `HeadlessSession` state rather than the
/// transcript. Session-wide facts (quota, cost, branch) stay in
/// `StatuslineStripView`; these describe the turn about to be sent, so they
/// live beside the send button instead.
///
/// Each segment is self-contained — it reads and writes only its own piece of
/// session state — so the row can later become reorderable/hideable without
/// special-casing any one of them.
struct ComposerControlsRow: View, ThemedView {
    @Environment(\.theme) var theme

    let headlessSession: HeadlessSession?

    var body: some View {
        HStack(spacing: 12) {
            if let headlessSession {
                PermissionModeControl(session: headlessSession)
                ModelControl(session: headlessSession)
                EffortControl(session: headlessSession)
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
        }
    }
}

private struct EffortControl: View, ThemedView {
    @Environment(\.theme) var theme
    @Bindable var session: HeadlessSession

    var body: some View {
        if let effort = session.effort {
            Menu {
                ForEach(AgentEffort.allCases) { option in
                    Button(option.label) { session.setEffort(option) }
                }
            } label: {
                segmentLabel(effort.label, foreground: foreground(for: attention(effort)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Changing effort has no control request (see `HeadlessSession.
            // setEffort`), so it sends an ordinary chat turn — that turn
            // appearing in the transcript is expected, not a bug.
            .help("Effort (sends a message to change)")
        }
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
    ComposerControlsRow(headlessSession: nil)
        .padding()
}
