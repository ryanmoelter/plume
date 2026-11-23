import SwiftUI
import Virtualization

/// A hidden VM tab unmounts its view; the VM keeps running in `VMManager`.
struct VMTabHost: View {
    let tab: TaskTab
    let isVisible: Bool

    var body: some View {
        if isVisible {
            VMTabView(tab: tab)
        } else {
            Color.clear
        }
    }
}

/// Views one slot of `VMManager`'s pool. Closing the tab never stops the VM; Release does.
struct VMTabView: View {
    let tab: TaskTab

    @State private var capturesSystemKeys = false
    @State private var actionError: String?
    @State private var isResetting = false

    private var vms: VMManager { .shared }

    private var owner: DeviceLeaseOwner {
        .tab(id: tab.id, app: DeviceLeaseCoordinator.shared.appSocket ?? "")
    }

    var body: some View {
        let slot = tab.vmSlot == 0 ? nil : vms.slot(tab.vmSlot)
        let phase = VMTabPhase.of(vmSlot: tab.vmSlot, slot: slot, hasDisplay: vms.displays[tab.vmSlot] != nil)
        VStack(spacing: 0) {
            if let slot, phase != .picker {
                toolbar(slot)
                Divider()
                content(phase, slot: slot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                picker
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .plumeID(AccessibilityID.vmActionError, value: actionError)
            }
        }
        .plumeID(AccessibilityID.vmTab, label: tab.vmSlot == 0 ? nil : VMPaths.key(tab.vmSlot), value: phase.label)
    }

    // MARK: Toolbar

    private func toolbar(_ slot: VMManager.Slot) -> some View {
        let lease = slot.lease
        let canReset = lease == nil && (slot.state == .idle || slot.state == .failed) && !isResetting
        return HStack(spacing: 12) {
            Text(slot.key)
                .font(.callout.monospaced().weight(.semibold))
                .plumeID(AccessibilityID.vmToolbarSlot, value: slot.key)
            Text(slot.state.rawValue)
                .foregroundStyle(.secondary)
                .plumeID(AccessibilityID.vmToolbarState, value: slot.state.rawValue)
            if let ip = slot.ip {
                Text(ip)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .plumeID(AccessibilityID.vmToolbarIP, value: ip)
            }
            if let lease {
                Text(holder(of: lease))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.vmToolbarHolder, value: lease.owner.description)
                (Text("expires ") + Text(lease.expiresAt, style: .relative))
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.vmToolbarExpiry, value: ISO8601DateFormatter().string(from: lease.expiresAt))
            }
            Spacer(minLength: 8)
            Toggle("Capture system keys", isOn: $capturesSystemKeys)
                .toggleStyle(.checkbox)
                .help("Send ⌘Tab, ⌘Space and other system shortcuts to the VM")
                .plumeID(
                    AccessibilityID.vmCaptureKeysToggle,
                    value: capturesSystemKeys ? "on" : "off",
                    invoke: { capturesSystemKeys.toggle() }
                )
            Button("Release") { release(slot) }
                .help("Stop the VM and end its lease. The clone is kept, so the next boot is warm.")
                .plumeID(AccessibilityID.vmReleaseButton, invoke: { release(slot) })
                .disabled(lease == nil)
            Button("Reset") { reset(slot) }
                .help("Delete this slot's clone, so its next boot starts from the base image")
                .plumeID(AccessibilityID.vmResetButton, invoke: { reset(slot) })
                .disabled(!canReset)
            Button("Change Slot") { choose(0) }
                .plumeID(AccessibilityID.vmChangeSlotButton, invoke: { choose(0) })
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func holder(of lease: VMManager.Lease) -> String {
        lease.owner.tabID == tab.id ? "held by this tab" : "held by \(lease.owner.description)"
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ phase: VMTabPhase, slot: VMManager.Slot) -> some View {
        switch phase {
        case .picker:
            EmptyView()
        case .idle:
            VStack(spacing: 10) {
                Text("\(slot.key) is stopped.")
                    .foregroundStyle(.secondary)
                Button("Start") { claim(slot.number) }
                    .plumeID(AccessibilityID.vmStartButton, invoke: { claim(slot.number) })
                    .disabled(isResetting)
            }
        case .booting(_, let state):
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(Self.bootText(state))
                    .foregroundStyle(.secondary)
            }
            .plumeID(AccessibilityID.vmBootProgress, value: state.rawValue)
        case .stopping:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Stopping…").foregroundStyle(.secondary)
            }
            .plumeID(AccessibilityID.vmBootProgress, value: VMSlotState.stopping.rawValue)
        case .failed(_, let message, _):
            VStack(spacing: 10) {
                Text(message)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 480)
                    .plumeID(AccessibilityID.vmErrorText, value: message)
                Button("Retry") { retry(slot) }
                    .plumeID(AccessibilityID.vmRetryButton, invoke: { retry(slot) })
            }
            .padding()
        case .running(let number, let hasDisplay):
            if hasDisplay {
                VMDisplayView(display: vms.displays[number], capturesSystemKeys: capturesSystemKeys)
                    .plumeID(AccessibilityID.vmSurface, value: slot.key)
            } else {
                Text("\(slot.key) is running with no display.")
                    .foregroundStyle(.secondary)
                    .plumeID(AccessibilityID.vmSurface, value: "no display")
            }
        }
    }

    private static func bootText(_ state: VMSlotState) -> String {
        switch state {
        case .cloning: "Preparing the clone…"
        case .starting: "Booting macOS…"
        default: "Waiting to boot…"
        }
    }

    // MARK: Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a VM").font(.headline)
            ForEach(vms.slots) { slot in
                let summary = Self.summary(of: slot)
                let isFree = slot.lease == nil && (slot.state == .idle || slot.state == .failed)
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.key).font(.body.monospaced())
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { choose(slot.number) }
                        .plumeID(AccessibilityID.vmPickerShowButton, label: slot.key, invoke: { choose(slot.number) })
                        .disabled(isFree)
                    Button("Claim") { claim(slot.number) }
                        .plumeID(AccessibilityID.vmPickerClaimButton, label: slot.key, invoke: { claim(slot.number) })
                        .disabled(!isFree)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                .plumeID(AccessibilityID.vmPickerRow, label: slot.key, value: summary)
            }
        }
        .frame(maxWidth: 420)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func summary(of slot: VMManager.Slot) -> String {
        guard let lease = slot.lease else { return slot.state.rawValue }
        return "\(slot.state.rawValue), held by \(lease.owner.description)"
    }

    // MARK: Actions

    private func choose(_ number: Int) {
        actionError = nil
        tab.vmSlot = number
    }

    private func claim(_ number: Int) {
        do {
            let claimed = try vms.claim(owner: owner, worktree: nil, branch: tab.branchName, preferred: number)
            choose(claimed.slot)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// A failed boot keeps its lease, and a claim by that lease's owner boots it again.
    private func retry(_ slot: VMManager.Slot) {
        guard let lease = slot.lease else { return claim(slot.number) }
        do {
            _ = try vms.claim(owner: lease.owner, worktree: lease.worktree, branch: lease.branch)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func release(_ slot: VMManager.Slot) {
        guard let lease = slot.lease else { return }
        do {
            try vms.release(slot.key, owner: lease.owner, force: true)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reset(_ slot: VMManager.Slot) {
        isResetting = true
        actionError = nil
        Task {
            defer { isResetting = false }
            do {
                try await vms.reset(slot.key)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// `VZVirtualMachineView` showing a slot's VM through `VMDisplay`, which keeps the VM's own calls on
/// its queue.
struct VMDisplayView: NSViewRepresentable {
    let display: VMDisplay?
    let capturesSystemKeys: Bool

    final class Coordinator {
        var attached: VMDisplay?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.automaticallyReconfiguresDisplay = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.capturesSystemKeys = capturesSystemKeys
        guard context.coordinator.attached !== display else { return }
        if let display {
            display.attach(to: view)
        } else {
            VMDisplay.detach(from: view)
        }
        context.coordinator.attached = display
    }

    static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: Coordinator) {
        VMDisplay.detach(from: view)
        coordinator.attached = nil
    }
}
