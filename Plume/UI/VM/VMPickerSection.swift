import SwiftUI

/// The device picker's rows for `VMManager`'s slots. Claiming or showing a slot turns the device
/// tab into a VM tab; a slot claimed here is the tab's own, as one claimed from the VM tab is.
struct VMPickerSection: View {
    let tab: TaskTab

    @State private var actionError: String?

    private var vms: VMManager { .shared }

    var body: some View {
        if VMManager.isSupported {
            ForEach(vms.slots) { slot in
                slotRow(slot)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .plumeID(AccessibilityID.vmPickerError, value: actionError)
            }
        } else {
            Text(VMManager.unsupportedMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .plumeID(AccessibilityID.vmPickerUnsupported, value: VMManager.unsupportedMessage)
        }
    }

    private func slotRow(_ slot: VMManager.Slot) -> some View {
        let row = VMPickerRow(slot)
        return HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.key).font(.body.monospaced())
                Text(row.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show") { show(slot.number) }
                .plumeID(AccessibilityID.vmPickerShowButton, label: slot.key, invoke: { show(slot.number) })
                .disabled(!row.canShow)
            Button("Claim") { claim(slot.number) }
                .plumeID(AccessibilityID.vmPickerClaimButton, label: slot.key, invoke: { claim(slot.number) })
                .disabled(!row.canClaim || !AppSettings.shared.labsVMsEnabled)
        }
        .padding(10)
        .plumeID(AccessibilityID.vmPickerRow, label: slot.key, value: row.summary)
    }

    private func show(_ number: Int) {
        actionError = nil
        TaskStore.showVM(slot: number, in: tab)
    }

    private func claim(_ number: Int) {
        actionError = nil
        Task {
            do {
                try await tab.claimVM(slot: number)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

@MainActor
extension TaskTab {
    /// The owner of a VM lease claimed from this tab, which renews while the tab exists.
    var vmLeaseOwner: DeviceLeaseOwner {
        .tab(id: id, app: DeviceLeaseCoordinator.shared.appSocket ?? "")
    }

    /// Claims `slot` for this tab, or boots its own lease there again, and shows it here.
    func claimVM(slot: Int) async throws {
        let claimed = try await VMManager.shared.claim(owner: vmLeaseOwner, worktree: nil, branch: branchName, preferred: slot)
        TaskStore.showVM(slot: claimed.slot, in: self)
    }
}
