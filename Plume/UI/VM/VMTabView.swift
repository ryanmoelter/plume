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

/// Views one slot of `VMManager`'s pool. A VM this tab claimed is its own: the lease renews while
/// the tab exists, and closing the tab stops the VM. A VM another owner holds is only shown. With no
/// slot, the tab goes back to being a device tab, whose picker lists the slots.
struct VMTabView: View {
    let tab: TaskTab

    @State private var capturesSystemKeys = false
    @State private var actionError: String?
    @State private var isResetting = false
    /// Another owner's lease this tab asked to release, until the user confirms or cancels.
    @State private var forceReleaseLease: VMManager.Lease?

    private var vms: VMManager { .shared }

    private var owner: DeviceLeaseOwner { tab.vmLeaseOwner }

    var body: some View {
        if VMManager.isSupported {
            supportedBody
        } else {
            Text(VMManager.unsupportedMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .plumeID(AccessibilityID.vmTab, value: VMManager.unsupportedMessage)
        }
    }

    @ViewBuilder
    private var supportedBody: some View {
        let slot = tab.vmSlot == 0 ? nil : vms.slot(tab.vmSlot)
        let phase = VMTabPhase.of(vmSlot: tab.vmSlot, slot: slot, hasDisplay: vms.displays[tab.vmSlot] != nil)
        VStack(spacing: 0) {
            if let slot, phase != .picker {
                toolbar(slot)
                Divider()
                content(phase, slot: slot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear.onAppear { TaskStore.showDevicePicker(in: tab) }
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
            if let lease, lease.owner.tabID != tab.id {
                Button("Force Release…") { forceReleaseLease = lease }
                    .help("Stop the VM and end \(lease.owner.description)'s lease on it")
                    .plumeID(AccessibilityID.vmReleaseButton, value: "force", invoke: { forceReleaseLease = lease })
            } else {
                Button("Release") { release(slot) }
                    .help("Stop the VM and end its lease. The clone is kept, so the next boot is warm.")
                    .plumeID(AccessibilityID.vmReleaseButton, invoke: { release(slot) })
                    .disabled(lease == nil && !slot.stillRunning)
            }
            Button("Reset") { reset(slot) }
                .help("Delete this slot's clone, so its next boot starts from the base image")
                .plumeID(AccessibilityID.vmResetButton, invoke: { reset(slot) })
                .disabled(!canReset)
            Button("Change Slot") { showDevicePicker() }
                .plumeID(AccessibilityID.vmChangeSlotButton, invoke: { showDevicePicker() })
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .alert(
            "Force release \(slot.key)?",
            isPresented: Binding(get: { forceReleaseLease != nil }, set: { if !$0 { forceReleaseLease = nil } }),
            presenting: forceReleaseLease
        ) { held in
            Button("Force Release", role: .destructive) { forceRelease(slot.number, held) }
                .plumeID(AccessibilityID.vmForceReleaseConfirmButton, invoke: { forceRelease(slot.number, held) })
            Button("Cancel", role: .cancel) {}
                .plumeID(AccessibilityID.vmForceReleaseCancelButton, invoke: { forceReleaseLease = nil })
        } message: { held in
            Text("\(held.owner.description) holds it. Releasing stops the VM, which ends whatever it is running there.")
        }
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
        case .resetting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Resetting…").foregroundStyle(.secondary)
            }
            .plumeID(AccessibilityID.vmBootProgress, value: VMSlotState.resetting.rawValue)
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
            if #available(macOS 27.0, *), hasDisplay {
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

    // MARK: Actions

    private func choose(_ number: Int) {
        actionError = nil
        tab.vmSlot = number
    }

    private func showDevicePicker() {
        actionError = nil
        TaskStore.showDevicePicker(in: tab)
    }

    private func claim(_ number: Int) {
        Task {
            do {
                let claimed = try await vms.claim(owner: owner, worktree: nil, branch: tab.branchName, preferred: number)
                choose(claimed.slot)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// A failed boot keeps its lease, and a claim by that lease's owner boots it again.
    private func retry(_ slot: VMManager.Slot) {
        guard let lease = slot.lease else { return claim(slot.number) }
        Task {
            do {
                _ = try await vms.claim(owner: lease.owner, worktree: lease.worktree, branch: lease.branch)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// This tab's own lease, or a slot with no lease whose VM didn't stop.
    private func release(_ slot: VMManager.Slot) {
        do {
            try vms.release(slot.key, owner: slot.lease?.owner ?? owner, force: false)
            showDevicePicker()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Releases only the lease the user confirmed, not one claimed since.
    private func forceRelease(_ number: Int, _ held: VMManager.Lease) {
        forceReleaseLease = nil
        guard let current = vms.slot(number), current.lease?.token == held.token else {
            actionError = "\(VMPaths.key(number))'s lease changed; nothing was released"
            return
        }
        do {
            try vms.release(current.key, owner: held.owner, force: true)
            showDevicePicker()
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
@available(macOS 27.0, *)
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
