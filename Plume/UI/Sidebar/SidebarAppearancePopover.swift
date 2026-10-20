import AppKit
import SwiftUI

/// A group's icon and color, edited from its context menu.
struct GroupAppearancePopover: View {
    @Bindable var group: TaskGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarTintPicker(
                selection: $group.tint,
                inherited: nil,
                plumeLabel: group.name
            )
            Divider()
            SidebarIconPicker(iconName: $group.iconName, plumeLabel: group.name)
        }
        .padding(14)
        .frame(width: 290)
        .plumeID(AccessibilityID.sidebarAppearancePopover, label: group.name)
    }
}

/// A task's color, edited from its context menu.
struct TaskColorPopover: View {
    @Bindable var task: WorkTask

    var body: some View {
        SidebarTintPicker(
            selection: $task.tint,
            inherited: task.group?.tint,
            plumeLabel: TitleStore.shared.displayTitle(for: task)
        )
        .padding(14)
        .plumeID(AccessibilityID.sidebarAppearancePopover, label: TitleStore.shared.displayTitle(for: task))
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
                captioned(inherited == nil ? "None" : "Group color") {
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
                captioned("Text") {
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
                colors: theme.colors.slots,
                ringColor: .primary,
                selectedSlot: selectedSlot,
                plumeID: AccessibilityID.sidebarTintSwatch,
                plumeLabel: plumeLabel,
                onSelect: { selection = .palette(slot: $0) }
            )
        }
    }

    private func captioned(_ caption: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(caption)
                .font(.caption)
                .emphasis(.secondary)
        }
    }
}

/// A curated grid of SF Symbols, plus a field for any other symbol's name.
private struct SidebarIconPicker: View {
    @Binding var iconName: String?
    let plumeLabel: String

    @Environment(\.theme) private var theme
    @State private var draft = ""

    static let curated = [
        "folder", "star", "flag", "bookmark", "tag", "bolt",
        "flame", "leaf", "ladybug", "hammer", "wrench.and.screwdriver", "paintbrush",
        "doc.text", "book", "lightbulb", "sparkles", "globe", "server.rack",
        "terminal", "cpu", "shippingbox", "cube", "testtube.2", "heart",
    ]

    static func isSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var draftIsInvalid: Bool {
        !trimmedDraft.isEmpty && !Self.isSymbol(trimmedDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon")
                .font(.subheadline.weight(.semibold))
                .emphasis(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.curated, id: \.self) { name in
                    symbolButton(name)
                }
            }
            HStack(spacing: 6) {
                TextField("Icon name", text: $draft, prompt: Text("SF Symbol name"))
                    .textFieldStyle(.roundedBorder)
                    .plumeID(
                        AccessibilityID.sidebarIconNameField,
                        label: plumeLabel,
                        value: draft,
                        setValue: { draft = $0 }
                    )
                Button {
                    iconName = nil
                    draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .emphasis(.secondary)
                .help("Remove the icon")
                .plumeID(AccessibilityID.sidebarIconClearButton, label: plumeLabel, invoke: {
                    iconName = nil
                    draft = ""
                })
                .disabled(iconName == nil && draft.isEmpty)
            }
            if draftIsInvalid {
                Text("No SF Symbol has that name")
                    .font(.caption)
                    .foregroundStyle(theme.colors.danger)
            }
        }
        .onAppear { draft = iconName ?? "" }
        .onChange(of: draft) { _, _ in
            let name = trimmedDraft
            if name.isEmpty {
                iconName = nil
            } else if Self.isSymbol(name) {
                iconName = name
            }
        }
    }

    private func symbolButton(_ name: String) -> some View {
        let isSelected = iconName == name
        return Button {
            draft = name
        } label: {
            Image(systemName: name)
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
