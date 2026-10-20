import SwiftUI

/// A sample task row for Settings, built from the real row's pieces so every
/// sidebar setting shows its effect.
struct SidebarTaskPreview: View {
    static let width: CGFloat = 240

    /// The Settings window installs no theme of its own, so the preview does,
    /// as the sidebar it imitates does.
    var body: some View {
        SidebarTaskPreviewContent()
            .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
    }
}

private struct SidebarTaskPreviewContent: View {
    private static let iconName = "person.2"

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let settings = AppSettings.shared
        let slot = settings.accentPaletteSlot
        let appearance = SidebarTaskAppearance(
            effective: SidebarPreviewTint.effective(accentSlot: slot),
            showsBar: settings.sidebarShowsTaskColorBar,
            colorsNames: settings.sidebarColorsTaskNames,
            colorsIcons: settings.sidebarColorsTaskIcons,
            bold: settings.sidebarBoldTaskNames
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
        .frame(width: SidebarTaskPreview.width)
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
