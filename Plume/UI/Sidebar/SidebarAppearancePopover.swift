import AppKit
import SwiftUI

/// A group's icon and color, edited from its context menu.
struct GroupAppearancePopover: View {
    @Bindable var group: TaskGroup

    var body: some View {
        SidebarAppearanceEditor(
            tint: $group.tint,
            inheritedTint: nil,
            iconName: $group.iconName,
            iconTint: group.tint,
            iconWeight: SidebarMetrics.headerWeight,
            plumeLabel: group.name
        )
    }
}

/// A task's icon and color, edited from its context menu.
struct TaskAppearancePopover: View {
    @Bindable var task: WorkTask

    var body: some View {
        let appearance = SidebarTaskAppearance(task: task, settings: .shared)
        SidebarAppearanceEditor(
            tint: $task.tint,
            inheritedTint: task.group?.tint,
            iconName: $task.iconName,
            iconTint: appearance.iconTint,
            iconWeight: appearance.weight,
            plumeLabel: TitleStore.shared.displayTitle(for: task)
        )
    }
}

private struct SidebarAppearanceEditor: View {
    @Binding var tint: SidebarTint?
    let inheritedTint: SidebarTint?
    @Binding var iconName: String?
    /// The color the real icon will take, or nil when it renders untinted.
    let iconTint: SidebarTint?
    let iconWeight: Font.Weight
    let plumeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarTintPicker(selection: $tint, inherited: inheritedTint, plumeLabel: plumeLabel)
            Divider()
            SidebarIconPicker(
                iconName: $iconName,
                tint: iconTint,
                weight: iconWeight,
                plumeLabel: plumeLabel
            )
        }
        .padding(14)
        .frame(width: 290)
        .plumeID(AccessibilityID.sidebarAppearancePopover, label: plumeLabel)
    }
}

/// No color, the theme's text color, or one of its 16 palette slots.
private struct SidebarTintPicker: View {
    @Binding var selection: SidebarTint?
    /// What a nil selection falls back to — a task's group color.
    let inherited: SidebarTint?
    let plumeLabel: String

    @Environment(\.theme) private var theme

    private var selectedSlot: Int? {
        if case .palette(let slot) = selection { slot } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color")
                .font(.subheadline.weight(.semibold))
                .emphasis(.secondary)
            HStack(spacing: 14) {
                CaptionedSwatch(inherited == nil ? "None" : "Group color") {
                    PaletteSwatch(
                        color: inherited.flatMap(theme.colors.color(for:)),
                        ringColor: .primary,
                        isSelected: selection == nil,
                        help: inherited == nil ? "No color" : "The group's color",
                        plumeID: AccessibilityID.sidebarTintSwatch,
                        plumeLabel: "\(plumeLabel) none",
                        select: { selection = nil }
                    ) {
                        if inherited == nil {
                            Rectangle()
                                .fill(.secondary)
                                .frame(width: 1, height: PaletteSwatchGrid.swatchSize)
                                .rotationEffect(.degrees(45))
                        }
                    }
                }
                CaptionedSwatch("Text") {
                    PaletteSwatch(
                        color: theme.colors.foreground,
                        ringColor: .primary,
                        isSelected: selection == .text,
                        help: "The theme's text color",
                        plumeID: AccessibilityID.sidebarTintSwatch,
                        plumeLabel: "\(plumeLabel) text",
                        select: { selection = .text }
                    )
                }
            }
            PaletteSwatchGrid(
                colors: ThemeChrome.paletteSlots.map(theme.colors.color(forSlot:)),
                ringColor: .primary,
                selectedSlot: selectedSlot,
                plumeID: AccessibilityID.sidebarTintSwatch,
                plumeLabel: plumeLabel,
                onSelect: { selection = .palette(slot: $0) }
            )
        }
    }

}

/// A field for any SF Symbol's name, a curated grid and the recently used custom icons.
private struct SidebarIconPicker: View {
    @Binding var iconName: String?
    let tint: SidebarTint?
    let weight: Font.Weight
    let plumeLabel: String

    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var original: String?

    static func isSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftIsInvalid: Bool {
        !trimmedDraft.isEmpty && !Self.isSymbol(trimmedDraft)
    }

    private var canRevert: Bool {
        iconName != original || draft != (original ?? "")
    }

    private var recent: [String] {
        AppSettings.shared.recentSidebarIcons
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon")
                .font(.subheadline.weight(.semibold))
                .emphasis(.secondary)
            HStack(spacing: 6) {
                preview
                TextField("Icon name", text: $draft, prompt: Text("SF Symbol name"))
                    .textFieldStyle(.roundedBorder)
                    .plumeID(
                        AccessibilityID.sidebarIconNameField,
                        label: plumeLabel,
                        value: draft,
                        setValue: { draft = $0 }
                    )
                Button(action: revert) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .help("Restore the icon from when this opened")
                .plumeID(AccessibilityID.sidebarIconRevertButton, label: plumeLabel, invoke: revert)
                .disabled(!canRevert)
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .help("Remove the icon")
                .plumeID(AccessibilityID.sidebarIconClearButton, label: plumeLabel, invoke: clear)
                .disabled(iconName == nil && draft.isEmpty)
            }
            if draftIsInvalid {
                Text("No SF Symbol has that name")
                    .font(.caption)
                    .foregroundStyle(theme.colors.danger)
            }
            grid(SidebarIcons.curated)
            if !recent.isEmpty {
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                    .emphasis(.secondary)
                grid(recent)
            }
        }
        .onAppear {
            draft = iconName ?? ""
            original = iconName
        }
        .onChange(of: draft) { _, _ in
            let name = trimmedDraft
            if name.isEmpty {
                iconName = nil
            } else if Self.isSymbol(name) {
                iconName = name
            }
        }
        .onDisappear {
            if draftIsInvalid {
                iconName = original
            } else {
                AppSettings.shared.recentSidebarIcons =
                    SidebarIcons.recording(iconName, in: AppSettings.shared.recentSidebarIcons)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if !trimmedDraft.isEmpty, Self.isSymbol(trimmedDraft) {
                symbol(trimmedDraft)
            } else {
                Color.clear
            }
        }
        .frame(width: 24, height: 24)
    }

    private func grid(_ names: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
            ForEach(names, id: \.self) { name in
                symbolButton(name)
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        let color = tint.flatMap(theme.colors.color(for:))
        return Image(systemName: name)
            .fontWeight(weight)
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
    }

    private func clear() {
        draft = ""
    }

    private func revert() {
        draft = original ?? ""
    }

    private func symbolButton(_ name: String) -> some View {
        let isSelected = iconName == name
        return Button {
            draft = name
        } label: {
            symbol(name)
                .frame(width: 28, height: 24)
                .background(
                    isSelected ? AnyShapeStyle(theme.colors.selection.opacity(0.25)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .plumeID(
            AccessibilityID.sidebarIconSwatch,
            label: "\(plumeLabel) \(name)",
            value: isSelected ? "selected" : nil,
            invoke: { draft = name }
        )
    }
}
