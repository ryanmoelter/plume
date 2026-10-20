import AppKit
import SwiftData
import SwiftUI

/// A group's name, icon and color, edited from its context menu or header.
struct GroupAppearancePopover: View {
    @Bindable var group: TaskGroup
    @State private var plumeLabel: String
    @State private var openingName: String

    init(group: TaskGroup) {
        self.group = group
        _plumeLabel = State(initialValue: group.name)
        _openingName = State(initialValue: group.name)
    }

    var body: some View {
        SidebarAppearanceEditor(
            tint: $group.tint,
            inheritedTint: nil,
            iconName: $group.iconName,
            iconTint: group.tint,
            iconWeight: SidebarMetrics.headerWeight,
            plumeLabel: plumeLabel,
            isLive: { group.isLive }
        ) {
            SidebarTextField(
                title: "Name",
                placeholder: "Group name",
                font: .title3,
                text: $group.name,
                plumeID: AccessibilityID.sidebarNameField,
                plumeLabel: plumeLabel
            )
        } onClose: {
            guard group.isLive else { return }
            group.settleName(fallback: openingName)
        }
    }
}

/// A task's name, description, icon and color, edited from its context menu.
struct TaskAppearancePopover: View {
    @Bindable var task: WorkTask
    @State private var label: String

    init(task: WorkTask) {
        self.task = task
        _label = State(initialValue: TitleStore.shared.displayTitle(for: task))
    }

    var body: some View {
        let appearance = SidebarTaskAppearance(task: task, settings: .shared)
        let generatedTitle = TitleStore.shared.generatedTitle(for: task)
        SidebarAppearanceEditor(
            tint: $task.tint,
            inheritedTint: task.group?.tint,
            iconName: $task.iconName,
            iconTint: appearance.iconTint,
            iconWeight: appearance.weight,
            plumeLabel: label,
            isLive: { task.isLive }
        ) {
            SidebarTextField(
                title: "Name",
                placeholder: TitleStore.namePlaceholder(generatedTitle: generatedTitle),
                font: .title3,
                text: $task.title,
                plumeID: AccessibilityID.sidebarNameField,
                plumeLabel: label
            )
            SidebarTextField(
                title: "Description",
                placeholder: "Description",
                font: .body,
                text: $task.taskDescription,
                plumeID: AccessibilityID.sidebarDescriptionField,
                plumeLabel: label
            )
        } onClose: {
            guard task.isLive else { return }
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title != task.title { task.title = title }
            let description = task.taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if description != task.taskDescription { task.taskDescription = description }
        }
    }
}

private struct SidebarTextField: View {
    let title: String
    let placeholder: String
    let font: Font
    @Binding var text: String
    let plumeID: String
    let plumeLabel: String

    var body: some View {
        TextField(title, text: $text, prompt: Text(placeholder))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .font(font)
            .accessibilityLabel(title)
            .plumeID(plumeID, label: plumeLabel, value: text, setValue: { text = $0 })
    }
}

private struct SidebarAppearanceEditor<Fields: View>: View {
    @Binding var tint: SidebarTint?
    let inheritedTint: SidebarTint?
    @Binding var iconName: String?
    /// The color the real icon will take, or nil when it renders untinted.
    let iconTint: SidebarTint?
    let iconWeight: Font.Weight
    let plumeLabel: String
    let isLive: () -> Bool
    @ViewBuilder let fields: Fields
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            fields
            Divider()
            SidebarTintPicker(selection: $tint, inherited: inheritedTint, plumeLabel: plumeLabel)
            Divider()
            SidebarIconPicker(
                iconName: $iconName,
                tint: iconTint,
                weight: iconWeight,
                plumeLabel: plumeLabel,
                isLive: isLive
            )
        }
        .onSubmit { dismiss() }
        .padding(14)
        .frame(width: 290)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Link(destination: URL(string: "https://developer.apple.com/sf-symbols/")!) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Download SF Symbols from Apple")
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .foregroundStyle(.tint)
                            Text("to browse icon options")
                                .font(.caption)
                                .emphasis(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .plumeID(AccessibilityID.sidebarSFSymbolsLink)
            }
        }
        .plumeID(AccessibilityID.sidebarAppearancePopover, label: plumeLabel)
        .onDisappear(perform: onClose)
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

/// A field for any SF Symbol's name, the recently used custom icons and a grid of popular ones.
private struct SidebarIconPicker: View {
    @Binding var iconName: String?
    let tint: SidebarTint?
    let weight: Font.Weight
    let plumeLabel: String
    let isLive: () -> Bool

    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var original: String?

    private static let cellWidth: CGFloat = 28
    private static let cellHeight: CGFloat = 24

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

    private var popular: [String] {
        SidebarIcons.popular(filled: AppSettings.shared.sidebarSuggestsFilledIcons)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .emphasis(.secondary)
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
            if !recent.isEmpty {
                sectionHeader("Recent")
                grid(recent)
            }
            sectionHeader("Popular")
            grid(popular)
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
            guard isLive() else { return }
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
            if draftIsInvalid {
                Image(systemName: "nosign")
                    .fontWeight(weight)
                    .emphasis(.subtle)
            } else if !trimmedDraft.isEmpty {
                symbol(trimmedDraft)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.cellWidth, height: Self.cellHeight)
    }

    private func grid(_ names: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 6), count: SidebarIcons.columns), spacing: 6) {
            ForEach(names, id: \.self) { name in
                symbolButton(name)
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        let color = tint.flatMap(theme.colors.color(for:))
        return Image(systemName: name)
            .symbolRenderingMode(SidebarIcons.renderingMode(twoTone: AppSettings.shared.sidebarTwoToneIcons))
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
                .frame(width: Self.cellWidth, height: Self.cellHeight)
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
