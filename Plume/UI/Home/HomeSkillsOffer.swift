import SwiftUI

/// Keeps the offer mounted while it fades and collapses, and after Not Now
/// while it shows its message.
struct HomeSkillsOfferSlot: View {
    let status: BundledSkillsStatus
    let isWanted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown: Bool
    @State private var isFaded = false
    @State private var showsLater = false

    private static let laterMessageDuration = Duration.milliseconds(1750)

    init(status: BundledSkillsStatus, isWanted: Bool) {
        self.status = status
        self.isWanted = isWanted
        _isShown = State(initialValue: isWanted)
    }

    var body: some View {
        if isShown || isWanted {
            HomeSkillsOffer(status: status, showsLater: $showsLater)
                .opacity(isFaded ? 0 : 1)
                .transition(.opacity)
                .onAppear {
                    guard isWanted else { return }
                    showsLater = false
                    isFaded = false
                    isShown = true
                }
                .task(id: showsLater) {
                    guard showsLater else { return }
                    try? await Task.sleep(for: Self.laterMessageDuration)
                    if !Task.isCancelled { collapse() }
                }
                .onChange(of: isWanted) { _, wanted in
                    if !wanted, !showsLater { collapse() }
                }
        }
    }

    private func collapse() {
        guard !reduceMotion else {
            isShown = false
            return
        }
        withAnimation(HomeSectionReveal.collapseFade) {
            isFaded = true
        } completion: {
            guard isFaded else { return }
            withAnimation(HomeSectionReveal.collapseHeight(count: 1)) {
                isShown = false
            }
        }
    }
}

/// Home's offer to install the bundled skills, shown until Plume owns one or
/// the user says not now.
struct HomeSkillsOffer: View, ThemedView {
    let status: BundledSkillsStatus
    @Binding var showsLater: Bool
    @Environment(\.theme) var theme
    @State private var settings = AppSettings.shared

    var body: some View {
        Group {
            if showsLater {
                Text("Install skills later in Settings")
                    .font(typography.body.font)
                    .emphasis(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                offer.transition(.opacity)
            }
        }
        .padding(dimensions.composerFieldInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: dimensions.panelCornerRadius)
                .strokeBorder(colors.attention, lineWidth: 1)
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: dimensions.panelContentInset) {
            Text("Install Plume's agent skills")
                .font(typography.body.font)
                .fontWeight(.semibold)
            Text("Teach agents how to use Plume, like managing devices, opening tabs, creating worktrees, and stacking PRs")
                .font(typography.body.font)
                .emphasis(.secondary)
            if status.linksCLIOnInstall(isHomebrewInstall: isHomebrewInstall) {
                Text("Also adds the `plume` command to ~/.local/bin.")
                    .font(typography.caption.font)
                    .emphasis(.secondary)
            }
            if let error = status.error(for: .home) {
                Text(error)
                    .font(typography.caption.font)
                    .foregroundStyle(colors.danger)
            }
            HStack(spacing: dimensions.panelContentInset) {
                Spacer()
                Button(action: dismiss) {
                    Text("Not Now").font(typography.body.font)
                }
                .buttonStyle(.bordered)
                .tint(colors.foreground)
                .plumeID(AccessibilityID.homeSkillsNotNowButton, invoke: dismiss)
                Button(action: install) {
                    Text("Install").font(typography.body.font)
                }
                .buttonStyle(.bordered)
                .tint(colors.selection)
                .plumeID(AccessibilityID.homeSkillsInstallButton, invoke: install)
                .disabled(status.isChanging)
            }
        }
    }

    private var isHomebrewInstall: Bool {
        UpdateController.shared.installSource == .homebrew
    }

    private func install() {
        status.installMissing(on: .home, isHomebrewInstall: isHomebrewInstall)
    }

    private func dismiss() {
        settings.bundledSkillsPromptDismissed = true
        status.clearError(for: .home)
        withAnimation(.easeInOut(duration: HomeSectionReveal.rowFadeDuration)) {
            showsLater = true
        }
    }
}
