import SwiftUI

/// A sample task row for Settings, built from the real row's pieces so every
/// sidebar setting shows its effect.
struct SidebarTaskPreview: View {
    static let width: CGFloat = 240
    private static let iconName = "person.2"

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let settings = AppSettings.shared
        let slot = settings.accentPaletteSlot
        let appearance = SidebarTaskAppearance(
            effective: SidebarPreviewTint.effective(accentSlot: slot),
            marker: settings.sidebarTaskMarker,
            colorsNames: settings.sidebarColorsTaskNames,
            tintsIcons: settings.sidebarTintsTaskIcons,
            bold: settings.sidebarBoldTaskNames,
            hasIcon: true
        )
        let color = { (tint: SidebarTint?) in
            tint.flatMap { SidebarPreviewTint.color(for: $0, accentSlot: slot, theme: theme) }
        }
        let iconName = settings.sidebarSuggestsFilledIcons
            ? SidebarIcons.filledVariant(of: Self.iconName)
            : Self.iconName

        VStack(alignment: .leading, spacing: 1) {
            SidebarIconTitle(
                icon: icon(iconName, appearance: appearance, color: color(appearance.iconTint), twoTone: settings.sidebarTwoToneIcons),
                iconMinWidth: SidebarMetrics.taskIconMinWidth,
                spacing: 5
            ) {
                title(appearance: appearance, color: color(appearance.titleTint))
            }
            Text("My project")
                .font(.caption)
                .emphasis(.secondary)
        }
        .padding(.vertical, 2)
        .sidebarRow(isSelected: false, tintBar: color(appearance.barTint))
        .frame(width: Self.width)
        .background(theme.colors.background ?? Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.colors.divider) }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sidebar preview")
        .plumeID(AccessibilityID.settingsSidebarPreview, label: "Sidebar preview")
    }

    @ViewBuilder
    private func icon(_ name: String, appearance: SidebarTaskAppearance, color: Color?, twoTone: Bool) -> some View {
        let image = Image(systemName: name)
            .symbolRenderingMode(SidebarIcons.renderingMode(twoTone: twoTone))
            .fontWeight(appearance.weight)
        if let color {
            image.foregroundStyle(color)
        } else {
            image.emphasis(.primary)
        }
    }

    @ViewBuilder
    private func title(appearance: SidebarTaskAppearance, color: Color?) -> some View {
        let text = Text("Do the thing")
            .lineLimit(1)
            .bold(appearance.weight == .bold)
        if let color {
            text.foregroundStyle(color)
        } else {
            text.emphasis(.primary)
        }
    }
}
