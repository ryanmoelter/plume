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
            .plumeID(
                AccessibilityID.keepAwakeModePicker,
                value: settings.keepAwakeMode.rawValue,
                setValue: { if let mode = KeepAwakeMode(rawValue: $0) { settings.keepAwakeMode = mode } }
            )

            summary
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

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

            Toggle("Keep awake for Remote Control", isOn: $settings.keepsAwakeForRemoteControl)
                .help("Off, a session being driven remotely stops holding the Mac awake on its own.")

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

            Toggle(isOn: $settings.keepsAwakeWithLidClosed) {
                // Red because this is what turns the sidebar row red.
                Text("Keep awake with the lid closed")
                    .foregroundStyle(lidToggleIsOn ? ChatRole.danger(for: colorScheme) : .primary)
            }
                .help(
                    "Only applies while \(AppIdentity.displayName) is holding the Mac awake, so on battery it "
                        + "also needs “Keep awake on battery”."
                )
                .plumeID(
                    AccessibilityID.keepAwakeLidToggle,
                    value: String(settings.keepsAwakeWithLidClosed),
                    setValue: { settings.keepsAwakeWithLidClosed = ($0 == "true" || $0 == "1") }
                )
                .disabled(!coordinator.lidOverrideStatus.canEngage)
                .opacity(coordinator.lidOverrideStatus.canEngage ? 1 : 0.5)

            if settings.keepsAwakeWithLidClosed {
                LabeledContent("Allow sleep when temperature is") {
                    ThermalCutoffMenu(selection: $settings.lidClosedThermalCutoff)
                }
            }

            lidClose

            #if DEBUG
            Divider()
            Toggle("Show power debug info", isOn: $settings.showsKeepAwakeDebugReadout)
                .font(.caption)
            if settings.showsKeepAwakeDebugReadout {
                KeepAwakeDebugReadout(coordinator: coordinator)
            }
            #endif
        }
        .padding(12)
        .frame(width: 340)
        .plumeID(AccessibilityID.keepAwakePanel)
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
        if guidance.offersInstall {
            Button("Install Sleep Helper…") {
                coordinator.installLidHelper()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .plumeID(AccessibilityID.keepAwakeLidInstallButton)
        } else if guidance.offersLoginItems {
            Button("Open Login Items…") {
                SMAppService.openSystemSettingsLoginItems()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .plumeID(AccessibilityID.keepAwakeLidApprovalButton)
        } else if let note = guidance.note {
            Text(note)
                .font(.callout)
                .emphasis(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .plumeID(AccessibilityID.keepAwakeLidNote)
        }
    }

    private var lidToggleIsOn: Bool {
        settings.keepsAwakeWithLidClosed && coordinator.lidOverrideStatus.canEngage
    }

    private var summary: Text {
        switch settings.keepAwakeMode {
        case .never:
            Text("Keep Awake is off.").foregroundStyle(Emphasis.secondary.textHierarchy)
        case .always:
            coordinator.isHolding ? holding : canSleep(notHoldingReason)
        case .auto:
            if coordinator.isHolding {
                holding
            } else if coordinator.reasons.isEmpty {
                canSleep("No work happening.")
            } else {
                canSleep(notHoldingReason)
            }
        }
    }

    /// Warning, like the sidebar row: the Mac staying up is worth knowing.
    private var holding: Text {
        Text("Keeping your Mac awake.").foregroundStyle(ChatRole.warning(for: colorScheme))
    }

    private func canSleep(_ reason: String) -> Text {
        (Text("Your Mac can sleep").bold() + Text(" • \(reason)")).foregroundStyle(Emphasis.secondary.textHierarchy)
    }

    /// Something wanted the Mac awake and it is still not held. On battery
    /// that is the setting; otherwise the request itself failed, which the
    /// panel should not dress up as a choice.
    private var notHoldingReason: String {
        switch coordinator.offReason {
        case .battery: "Your Mac is on battery."
        case .batteryLow(let percent): "Battery is at \(percent)%."
        case .refused, nil: "macOS refused."
        }
    }

    private var batteryCutoffLabel: String {
        settings.keepAwakeBatteryCutoffPercent == 0
            ? "No battery cutoff"
            : "Allow sleep below \(settings.keepAwakeBatteryCutoffPercent)%"
    }

    /// Falls back to the task's title, because a tab only has one once its
    /// agent has named the conversation.
    private func title(for reason: KeepAwakeReason) -> String {
        if reason.kind == .remoteControl,
           AgentSessionManager.shared.existingSession(for: reason.tabID) is CodexSession {
            return "Codex Remote Control"
        }
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .help(detail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .plumeID(AccessibilityID.keepAwakeReasonRow, label: title)
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
        case .backgroundTask(let kind, let description): description ?? Self.word(for: kind)
        }
    }

    private static func word(for kind: BackgroundTaskTracker.Kind) -> String {
        switch kind {
        case .monitor: "Monitor"
        case .backgroundCommand: "Background"
        case .workflow: "Workflow"
        }
    }
}
