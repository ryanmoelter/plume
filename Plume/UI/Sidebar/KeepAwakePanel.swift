import ServiceManagement
import SwiftData
import SwiftUI

/// Shows whether the Mac is being held awake, everything holding it, and the
/// controls over that.
struct KeepAwakePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = KeepAwakeCoordinator.shared
    @State private var settings = AppSettings.shared
    @Query private var tasks: [WorkTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Keep Awake", selection: $settings.keepAwakeMode) {
                ForEach(KeepAwakeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.keepAwakeModePicker)

            Text(summary)
                .font(.callout)
                .emphasis(.secondary)

            if settings.keepAwakeMode != .never, !coordinator.reasons.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(coordinator.reasons) { reason in
                            KeepAwakeReasonRow(reason: reason, title: title(for: reason)) {
                                Notifier.shared.pendingRoute = Notifier.Route(
                                    taskID: reason.taskID,
                                    tabID: reason.tabID
                                )
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Divider()

            Toggle("Keep awake on battery", isOn: $settings.keepsAwakeOnBattery)
                .help("Holding a Mac awake on battery drains it, and the system may ignore the request anyway.")

            if settings.keepsAwakeOnBattery {
                Stepper(
                    batteryCutoffLabel,
                    value: $settings.keepAwakeBatteryCutoffPercent,
                    in: 0...100,
                    step: 5
                )
                .help("The hold releases once the battery drops to or below this percentage, unless it's charging.")
            }

            Toggle("Keep awake with the lid closed", isOn: $settings.keepsAwakeWithLidClosed)
                .disabled(!coordinator.lidOverrideStatus.canEngage)
                .help(
                    "Only applies while Plume is holding the Mac awake, so on battery it "
                        + "also needs “Keep awake on battery”."
                )
                .accessibilityIdentifier(AccessibilityID.keepAwakeLidToggle)

            if settings.keepsAwakeWithLidClosed {
                Picker("Allow sleep when temperature is", selection: $settings.lidClosedThermalCutoff) {
                    ForEach(ThermalCutoffLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .help("A shut lid can't shed heat as well as an open one, so the lid override releases and the Mac may sleep once it reaches this thermal level.")
                .accessibilityIdentifier(AccessibilityID.keepAwakeThermalPicker)
            }

            lidClose
        }
        .padding(12)
        .frame(width: 340)
        .accessibilityIdentifier(AccessibilityID.keepAwakePanel)
        .onAppear { coordinator.refreshLidOverride() }
    }

    private var guidance: LidCloseGuidance {
        .resolve(
            mode: settings.keepAwakeMode,
            wantsLidClosed: settings.keepsAwakeWithLidClosed,
            override: coordinator.lidOverrideStatus,
            pausedForHeat: coordinator.lidOverridePausedForHeat
        )
    }

    @ViewBuilder
    private var lidClose: some View {
        if let summary = guidance.summary {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary)
                    .font(.caption)
                    .emphasis(.secondary)

                if let explanation = guidance.explanation {
                    Text(explanation)
                        .font(.caption)
                        .emphasis(.subtle)
                }

                if guidance.offersSystemSettings {
                    Button("Open Battery Settings…") {
                        SystemSettingsLink.battery.open()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if guidance.offersInstall {
                    Button("Install Sleep Helper…") {
                        coordinator.installLidHelper()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier(AccessibilityID.keepAwakeLidInstallButton)
                }

                if guidance.offersLoginItems {
                    Button("Open Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier(AccessibilityID.keepAwakeLidApprovalButton)
                }
            }
            .accessibilityIdentifier(AccessibilityID.keepAwakeLidNote)
        }
    }

    private var summary: String {
        switch settings.keepAwakeMode {
        case .never:
            "Keep Awake is off."
        case .always:
            coordinator.isHolding ? "Holding the Mac awake." : notHoldingReason
        case .auto:
            if coordinator.isHolding {
                "Holding the Mac awake."
            } else if coordinator.reasons.isEmpty {
                "Not holding — nothing needs it."
            } else {
                notHoldingReason
            }
        }
    }

    /// Something wanted the Mac awake and it is still not held. On battery
    /// that is the setting; otherwise the request itself failed, which the
    /// panel should not dress up as a choice.
    private var notHoldingReason: String {
        switch coordinator.offReason {
        case .battery: "Not holding — the Mac is on battery."
        case .batteryLow(let percent): "Not holding — battery is at \(percent)%."
        case .refused, nil: "Not holding — the system refused."
        }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Stop below \(settings.keepAwakeBatteryCutoffPercent)%"
    }

    /// Falls back to the task's title, because a tab only has one once its
    /// agent has named the conversation.
    private func title(for reason: KeepAwakeReason) -> String {
        if let tabTitle = TitleStore.shared.title(forTab: reason.tabID), !tabTitle.isEmpty {
            return tabTitle
        }
        guard let task = tasks.first(where: { $0.id == reason.taskID }) else { return "Untitled" }
        return TitleStore.shared.displayTitle(for: task)
    }
}

private struct KeepAwakeReasonRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let reason: KeepAwakeReason
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(detail)
                    .font(.caption)
                    .emphasis(.subtle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.keepAwakeReasonRow)
    }

    @ViewBuilder
    private var icon: some View {
        switch reason.kind {
        case .working(let status):
            StatusBadge(status: status)
        case .remoteControl:
            Image(systemName: StatusSymbol.remoteControl.name)
                .foregroundStyle(ChatRole.attention(for: colorScheme))
        case .backgroundTask:
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(ChatRole.attention(for: colorScheme))
        }
    }

    private var detail: String {
        switch reason.kind {
        case .working(.working): "Working"
        case .working(.planApproval): "Plan"
        case .working(.questionAsked): "Question"
        case .working(.permissionNeeded): "Permission"
        case .working(.needsTerminalInput): "Waiting"
        case .working: "Active"
        case .remoteControl: "Remote"
        case .backgroundTask(.monitor): "Monitor"
        case .backgroundTask(.backgroundCommand): "Background"
        case .backgroundTask(.workflow): "Workflow"
        }
    }
}
