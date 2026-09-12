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
    let headlessSession: HeadlessSession?
    /// The plan a conversation has produced, when it's closed rather than
    /// minimized or expanded — `ChatTabView` owns `PlanPresentation` and
    /// decides when that's true. Minimized keeps its own dock bar above the
    /// composer; expanded is a full overlay with nothing to open from here.
    var showsPlanButton = false
    var onOpenPlan: () -> Void = {}

    /// The row's own width, which the parent sets: every segment hugs its
    /// content and the leading `Spacer` absorbs the rest, so the form the
    /// segments take can never change this measurement.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: dimensions.panelContentInset) {
            if showsPlanButton {
                PlanButton(form: form, action: onOpenPlan)
            }
            Spacer(minLength: 0)
            ModelControl(state: settings, form: form)
            EffortControl(state: settings, form: form)
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

    /// The measured width belongs to the whole row, Plan button included, so
    /// its own estimated width comes off the top before the three next-turn
    /// controls decide whether they fit.
    private var form: ComposerControlsForm {
        let planReservation = showsPlanButton
            ? ComposerControlsMetrics.segmentWidth(label: "Plan") + dimensions.panelContentInset
            : 0
        return ComposerControlsMetrics.form(
            availableWidth: availableWidth - planReservation,
            labels: ComposerControlLabels.all(state: settings),
            spacing: dimensions.panelContentInset
        )
    }
}

/// The three segment labels, in one place so the row can measure exactly what
/// the controls will draw.
enum ComposerControlLabels {
    @MainActor
    static func all(state: ComposerSettings) -> [String] {
        [model(state), state.effort.label, state.permissionMode?.label].compactMap { $0 }
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
    /// The chevron a segment draws — `.menuStyle(.borderlessButton)`'s own
    /// for the three menus, `PlanButton`'s manual one for the same width.
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
/// so the tint never lands. That style also supplies the one chevron these
/// labels need, so none of them draws its own — `showsTrailingChevron` is for
/// `PlanButton`, a plain `Button` with no menu style to draw one for it.
struct ComposerSegmentLabel: View, ThemedView {
    @Environment(\.theme) var theme

    let systemImage: String
    let text: String
    var showsText = true
    var showsTrailingChevron = false
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
        let icon = Text("\(Image(systemName: systemImage))")
        guard showsText else { return icon }
        var result = icon + Text("  ") + Text(text)
        if showsTrailingChevron {
            result = result + Text(" \(Image(systemName: "chevron.right"))")
        }
        return result
    }
}

/// The plan a conversation has produced, when it exists and is closed. Sits
/// on the row's leading edge, across the `Spacer` from the next-turn
/// controls it shares no subject with — a document the conversation already
/// wrote, not a setting for the message being composed.
///
/// The chevron marks it clickable the way a disclosure indicator would; a
/// plain `Button` draws none of its own the way `.menuStyle(.borderlessButton)`
/// does for the menu segments beside it.
private struct PlanButton: View, ThemedView {
    @Environment(\.theme) var theme
    let form: ComposerControlsForm
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComposerSegmentLabel(
                systemImage: StatusSymbol.plan.name,
                text: "Plan",
                showsText: form.showsLabels,
                showsTrailingChevron: true,
                foreground: colors.foreground,
                height: dimensions.composerControlHeight
            )
        }
        .buttonStyle(.plain)
        .help("Open the plan this conversation produced")
        .accessibilityLabel("Plan")
        .accessibilityIdentifier(AccessibilityID.planLinkButton)
    }
}

/// A mode this UI does not offer still shows its reported name — better a
/// truthful unfamiliar label than a familiar wrong one.
private struct PermissionModeControl: View, ThemedView {
    @Environment(\.theme) var theme
    let state: ComposerSettings
    let form: ComposerControlsForm

    var body: some View {
        if let mode = state.permissionMode {
            Menu {
                ForEach(PermissionMode.allCases) { option in
                    Button(option.label, systemImage: option.symbol) { state.setPermissionMode(option) }
                }
            } label: {
                ComposerSegmentLabel(
                    systemImage: mode.symbol,
                    text: mode.label,
                    showsText: form.showsLabels,
                    foreground: foreground(for: attention(mode)),
                    height: dimensions.composerControlHeight
                )
                .unconfirmed(state.isModeAndModelUnconfirmed)
            }
            .menuStyle(.borderlessButton)
            .help(state.modeAndModelHelp("Permission mode: \(mode.label)"))
            .accessibilityLabel("Permission mode")
            .accessibilityValue(mode.label)
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
    let form: ComposerControlsForm

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
            ComposerSegmentLabel(
                systemImage: "brain",
                text: label,
                showsText: form.showsLabels,
                foreground: colors.foreground,
                height: dimensions.composerControlHeight
            )
            .unconfirmed(state.isModelAwaitingConfirmation)
        }
        .menuStyle(.borderlessButton)
        .help(state.modeAndModelHelp("Model: \(label)"))
        .accessibilityLabel("Model")
        .accessibilityValue(label)
        .accessibilityIdentifier(AccessibilityID.composerModelControl)
        .popover(isPresented: $isAskingForCustomID) {
            CustomModelIDField(id: $customID) {
                state.setModel(AgentModel(unrecognizedID: $0))
            }
        }
    }

    private var label: String { ComposerControlLabels.model(state) }
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
    let form: ComposerControlsForm

    var body: some View {
        Menu {
            ForEach(AgentEffort.allCases) { option in
                Button(option.label, systemImage: option.symbol) { state.setEffort(option) }
            }
        } label: {
            // Nothing reports the CLI's own effort back (see `HeadlessSession.
            // setEffort`), so an untouched tab shows the app default, which is
            // also what seeds the session.
            ComposerSegmentLabel(
                systemImage: state.effort.symbol,
                text: state.effort.label,
                showsText: form.showsLabels,
                foreground: foreground(for: attention(state.effort)),
                height: dimensions.composerControlHeight
            )
        }
        .menuStyle(.borderlessButton)
        // Changing effort has no control request, so it sends an ordinary
        // chat turn — that turn appearing in the transcript is expected.
        .help("Effort: \(state.effort.label) (changing it sends a message)")
        .accessibilityLabel("Effort")
        .accessibilityValue(state.effort.label)
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

extension PermissionMode {
    /// One symbol per case, so the collapsed form still tells the four modes
    /// apart. `plan` matches `PlanButton`'s own icon, so the mode and the
    /// document it produces read as the same concept.
    var symbol: String {
        switch self {
        case .plan: return StatusSymbol.plan.name
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
        }
    }
}

extension View {
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
