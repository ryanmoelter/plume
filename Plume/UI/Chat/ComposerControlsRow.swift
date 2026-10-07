import AppKit
import SwiftUI

/// What the *next* message will do: model, effort and permission mode, in the
/// composer beside the send button. The dropdowns read `HeadlessSession`
/// state rather than the transcript.
///
/// Session-wide facts — where this runs, quota, cost, Remote Control — sit in
/// the statusline below instead; these describe the turn about to be sent.
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
    let headlessSession: (any AgentSession)?

    /// The row's own width, which the parent sets: every segment hugs its
    /// content and the leading `Spacer` absorbs the rest, so the form the
    /// segments take can never change this measurement.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        // Resolved once per render: the defaults come from the CLI's settings
        // files, and four separate reads here would stat them four times.
        let settings = settings
        let form = form(state: settings)
        HStack(spacing: dimensions.panelContentInset) {
            Spacer(minLength: 0)
            ModelControl(state: settings, form: form)
            EffortControl(state: settings, form: form)
            if tab.provider == .codex {
                CodexCollaborationControl(state: settings, form: form)
            }
            PermissionModeControl(state: settings, form: form)
        }
        .font(typography.caption.font)
        // The row sits level with the send and stop circles beside it, so
        // every segment takes their height rather than its own text's.
        .frame(minHeight: dimensions.composerControlHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private var settings: ComposerSettings {
        ComposerSettings(
            session: headlessSession,
            tab: tab,
            defaults: .resolved(task: task)
        )
    }

    private func form(state: ComposerSettings) -> ComposerControlsForm {
        ComposerControlsMetrics.form(
            availableWidth: availableWidth,
            labels: ComposerControlLabels.all(state: state),
            spacing: dimensions.panelContentInset
        )
    }
}

/// The three segment labels, in one place so the row can measure exactly what
/// the controls will draw.
enum ComposerControlLabels {
    @MainActor
    static func all(state: ComposerSettings) -> [String] {
        [model(state), state.effort.label,
         state.provider == .codex ? state.collaborationMode.label : nil,
         state.permissionPreset?.label].compactMap { $0 }
    }

    /// A tab that has never chosen one launches without `--model` and runs on
    /// the CLI's configured model, so the label names that rather than going
    /// blank — and marks it a default, since nothing has been pinned.
    @MainActor
    static func model(_ state: ComposerSettings) -> String {
        guard let model = state.model else { return "Model" }
        return state.isModelDefaulted ? "Default (\(model.label))" : model.label
    }
}

/// Whether the segments name themselves or collapse to their icons.
enum ComposerControlsForm {
    case labels
    case iconsOnly

    var showsLabels: Bool { self == .labels }
}

/// Whether the three labelled segments fit the width the row was given.
///
/// The widths are estimates from character counts rather than measurements:
/// the decision only needs to be right within a segment's width, and a real
/// measurement would mean laying the row out twice. Biased to collapse
/// slightly early, since a clipped control is worse than an early icon.
enum ComposerControlsMetrics {
    /// Average advance of the caption font, rounded up.
    static let glyphWidth: CGFloat = 6.5
    static let iconWidth: CGFloat = 15
    /// The chevron a segment draws after its label.
    static let chevronWidth: CGFloat = 13
    static let iconToLabelGap: CGFloat = 4

    static func segmentWidth(label: String) -> CGFloat {
        iconWidth + iconToLabelGap + CGFloat(label.count) * glyphWidth + chevronWidth
    }

    static var collapsedSegmentWidth: CGFloat { iconWidth + chevronWidth }

    static func requiredWidth(labels: [String], spacing: CGFloat) -> CGFloat {
        guard !labels.isEmpty else { return 0 }
        let segments = labels.reduce(0) { $0 + segmentWidth(label: $1) }
        return segments + spacing * CGFloat(labels.count - 1)
    }

    /// An unmeasured row shows labels: the first pass renders before any
    /// geometry arrives, and starting collapsed would flash icons on every
    /// wide window.
    static func form(availableWidth: CGFloat, labels: [String], spacing: CGFloat) -> ComposerControlsForm {
        guard availableWidth > 0 else { return .labels }
        return requiredWidth(labels: labels, spacing: spacing) <= availableWidth ? .labels : .iconsOnly
    }
}

/// A menu segment's label: its icon, and its text unless the row has
/// collapsed.
///
/// The icon is interpolated into the `Text` rather than left as an `Image`:
/// the popup button `.menuStyle(.borderlessButton)` draws renders a bare
/// image as a template in its own control color and drops `foregroundStyle`,
/// so the tint never lands. That style supplies its own chevron; a label
/// over a `SymbolMenuButton` has none, so it asks for `.menu`.
struct ComposerSegmentLabel: View, ThemedView {
    @Environment(\.theme) var theme

    enum Indicator {
        case none
        /// Opens a menu, and shows even in the collapsed form.
        case menu
    }

    let systemImage: String
    let text: String
    var showsText = true
    var indicator = Indicator.none
    let foreground: Color
    /// The control height the segment centres itself in. Nil sizes it to one
    /// caption line instead, which is what keeps an icon-only statusline
    /// segment level with the text beside it.
    var height: CGFloat?

    var body: some View {
        label
            .foregroundStyle(foreground)
            .lineLimit(1)
            // A symbol whose glyph box overflows the line grows the run, and
            // the extra sits above the baseline: `.slash` variants are 2pt
            // taller than their plain form. Pinning the run to the bottom of
            // one caption line puts every variant on the same baseline, so a
            // segment holds still as its icon changes.
            .frame(height: typography.caption.lineHeight, alignment: .bottom)
            .frame(height: height)
    }

    private var label: Text {
        var result = Text("\(Image(systemName: systemImage))")
        if showsText {
            result = result + Text("  ") + Text(text)
        }
        switch indicator {
        case .none:
            break
        case .menu:
            result = result + Text(" ")
                + Text(Image(systemName: "chevron.down")).font(.system(size: 9, weight: .semibold))
        }
        return result
    }
}

/// A mode this UI does not offer still shows its reported name — better a
/// truthful unfamiliar label than a familiar wrong one.
private struct PermissionModeControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    var body: some View {
        if let preset = state.permissionPreset {
            ComposerSegmentLabel(
                systemImage: symbol(for: preset),
                text: preset.label,
                showsText: form.showsLabels,
                indicator: .menu,
                foreground: foreground(for: attention(preset)),
                height: dimensions.composerControlHeight
            )
            .overlay {
                SymbolMenuButton(title: "Permission mode", value: preset.label, options: state.permissionPresets.map { option in
                    SymbolMenuOption(title: option.label, systemImage: symbol(for: option), isSelected: option == preset) {
                        state.setPermissionPreset(option)
                    }
                })
            }
            .help(state.modeAndModelHelp("Permission mode: \(preset.label)"))
            .accessibilityLabel("Permission mode")
            .accessibilityValue(preset.label)
            .plumeID(AccessibilityID.composerPermissionModeControl)
        }
    }

    /// Bypassing every permission check is worth flagging; the rest are
    /// ordinary working modes.
    private func attention(_ preset: AgentPermissionPreset) -> StatuslineAttention {
        preset.id == PermissionMode.bypassPermissions.rawValue || preset == .codexDangerFullAccess ? .red : .neutral
    }

    /// Claude's own modes carry a symbol per case; Codex's danger-level
    /// presets have no such enum, so they're matched by id instead.
    private func symbol(for preset: AgentPermissionPreset) -> String {
        if let mode = PermissionMode(rawValue: preset.id) { return mode.symbol }
        switch preset {
        case .codexReadOnly: return "eye"
        case .codexWorkspace: return "folder"
        case .codexDangerFullAccess: return "exclamationmark.triangle.fill"
        default: return "lock.shield"
        }
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        StatuslineColors.foreground(for: attention, colors: colors)
    }
}

private struct ModelControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    @State private var isAskingForCustomID = false
    @State private var customID = ""
    @State private var customProvider: AgentProviderKind = .claudeCode

    var body: some View {
        ModelSegmentLabel(
            provider: state.provider,
            text: label,
            showsText: form.showsLabels,
            foreground: colors.foreground,
            height: dimensions.composerControlHeight
        )
        .overlay {
            ModelMenuButton(state: state, label: label) { provider in
                customProvider = provider
                isAskingForCustomID = true
            }
        }
        .help(state.modeAndModelHelp("Model: \(label)"))
        .accessibilityLabel("Model")
        .accessibilityValue(label)
        .plumeID(AccessibilityID.composerModelControl)
        .popover(isPresented: $isAskingForCustomID) {
            CustomModelIDField(id: $customID) {
                state.setModel(AgentModel(unrecognizedID: $0), provider: customProvider)
            }
        }
    }

    private var label: String { ComposerControlLabels.model(state) }


}

private struct ModelSegmentLabel: View, ThemedView {
    @Environment(\.theme) var theme
    let provider: AgentProviderKind
    let text: String
    let showsText: Bool
    let foreground: Color
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            AgentProviderIcon(provider: provider, size: 12)
            if showsText { Text(text) }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(foreground)
        .lineLimit(1)
        .frame(height: typography.caption.lineHeight, alignment: .center)
        .frame(height: height)
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
            TextField("Model ID", text: $id)
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
    let form: ComposerControlsForm

    var body: some View {
        // Nothing reports the CLI's own effort back (see `HeadlessSession.
        // setEffort`), so an untouched tab shows the app default, which is
        // also what seeds the session.
        ComposerSegmentLabel(
            systemImage: state.effort.symbol,
            text: state.effort.label,
            showsText: form.showsLabels,
            indicator: .menu,
            foreground: foreground(for: attention(state.effort)),
            height: dimensions.composerControlHeight
        )
        .overlay {
            SymbolMenuButton(title: "Effort", value: state.effort.label, options: state.efforts.map { option in
                SymbolMenuOption(title: option.label, systemImage: option.symbol, isSelected: option == state.effort) {
                    state.setEffort(option)
                }
            })
        }
        // Changing effort has no control request, so it sends an ordinary
        // chat turn — that turn appearing in the transcript is expected.
        .help(state.provider == .codex
            ? "Effort: \(state.effort.label) (applies to the next turn)"
            : "Effort: \(state.effort.label) (changing it sends a message)")
        .accessibilityLabel("Effort")
        .accessibilityValue(state.effort.label)
        .plumeID(AccessibilityID.composerEffortControl)
    }

    /// Matches `statusline.sh`'s `effort_seg`: `xhigh`/`max` need attention.
    private func attention(_ level: AgentEffort) -> StatuslineAttention {
        switch level {
        case .xhigh, .max, .ultra: return .yellow
        default: return .neutral
        }
    }

    private func foreground(for attention: StatuslineAttention) -> Color {
        StatuslineColors.foreground(for: attention, colors: colors)
    }
}

extension PermissionMode {
    /// One symbol per case, so the collapsed form still tells the four modes
    /// apart. `plan` matches the info pane's plan row, so the mode and the
    /// document it produces read as the same concept.
    var symbol: String {
        switch self {
        case .plan: return StatusSymbol.plan.name
        case .manual: return "hand.raised"
        case .acceptEdits: return "pencil.line"
        case .auto: return "bolt.fill"
        case .bypassPermissions: return "exclamationmark.triangle.fill"
        }
    }
}

extension AgentEffort {
    /// The gauge family's own ladder, so the levels read as a scale rather
    /// than five unrelated icons.
    var symbol: String {
        switch self {
        case .low: return "gauge.with.dots.needle.0percent"
        case .medium: return "gauge.with.dots.needle.33percent"
        case .high: return "gauge.with.dots.needle.50percent"
        case .xhigh: return "gauge.with.dots.needle.67percent"
        case .max: return "gauge.with.dots.needle.100percent"
        case .ultra: return "bolt.circle"
        default: return "gauge.with.dots.needle.50percent"
        }
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
