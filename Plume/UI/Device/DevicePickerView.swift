import SwiftUI

/// Lists physical devices and running emulators to show, and AVDs to boot.
/// Discovery runs only while this view is on screen.
struct DevicePickerView: View {
    let onConnect: (PhysicalDevice) -> Void
    let onAttach: (RunningEmulator) -> Void
    let onBoot: (AVD) -> Void

    @State private var lookup: AndroidSDKLookup?
    @State private var avds: [AVD] = []
    private var discovery: EmulatorDiscovery { .shared }
    private var physicalDiscovery: PhysicalDeviceDiscovery { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Android Device", systemImage: "smartphone")
                    .font(.title2.weight(.semibold))
                content
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            discovery.retain()
            physicalDiscovery.retain()
        }
        .onDisappear {
            discovery.release()
            physicalDiscovery.release()
        }
        .task { await load(refresh: false) }
    }

    @ViewBuilder
    private var content: some View {
        switch lookup {
        case nil:
            ProgressView().controlSize(.small)
        case .notFound(let searched):
            VStack(alignment: .leading, spacing: 8) {
                Text("No Android SDK or adb was found.").font(.headline)
                Text("Plume looked in:").foregroundStyle(.secondary)
                ForEach(searched, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("Look Again") { Task { await load(refresh: true) } }
                    .plumeID(AccessibilityID.devicePickerRetryButton)
            }
        case .found(let sdk):
            physicalSection
            emulatorSections(hasEmulator: sdk.emulatorURL != nil)
        }
    }

    private var physicalSection: some View {
        section("Devices") {
            if physicalDiscovery.devices.isEmpty {
                placeholder("No devices are connected. Connect one over USB with USB debugging on.")
            }
            ForEach(physicalDiscovery.devices) { device in
                row(
                    title: device.displayName,
                    detail: detail(for: device),
                    action: "Show",
                    id: AccessibilityID.devicePickerPhysicalRow,
                    label: device.serial
                ) { onConnect(device) }
                .disabled(!device.isReady)
            }
        }
    }

    private func detail(for device: PhysicalDevice) -> String {
        switch device.state {
        case .ready: device.serial
        case .unauthorized: "Allow USB debugging on the device."
        case .offline: "The device is offline. Reconnect it."
        case .other(let state): "adb reports it as \(state)."
        }
    }

    @ViewBuilder
    private func emulatorSections(hasEmulator: Bool) -> some View {
        section("Running Emulators") {
            if discovery.running.isEmpty {
                placeholder("No emulators are running.")
            }
            ForEach(discovery.running, id: \.self) { emulator in
                row(
                    title: emulator.avdName,
                    detail: emulator.grpcToken == nil
                        ? "Can't attach: it published no gRPC token."
                        : emulator.adbSerial,
                    action: "Show",
                    id: AccessibilityID.devicePickerRunningRow,
                    label: emulator.avdID
                ) { onAttach(emulator) }
                .disabled(emulator.grpcToken == nil)
            }
        }
        section("Available Emulators") {
            let available = avds.filter { avd in !discovery.running.contains { $0.avdID == avd.id } }
            if !hasEmulator {
                placeholder("The Android emulator isn't installed. Install it with Android Studio's SDK Manager.")
            } else if available.isEmpty {
                placeholder(avds.isEmpty ? "No virtual devices exist. Create one in Android Studio." : "Every virtual device is running.")
            }
            ForEach(available) { avd in
                row(
                    title: avd.displayName,
                    detail: avd.id,
                    action: "Boot",
                    id: AccessibilityID.devicePickerAvailableRow,
                    label: avd.id
                ) { onBoot(avd) }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(spacing: 0) { rows() }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private func row(
        title: String,
        detail: String?,
        action: String,
        id: String,
        label: String,
        perform: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action, action: perform)
                .plumeID(id, label: label, invoke: perform)
        }
        .padding(10)
    }

    private func load(refresh: Bool) async {
        let lookup = await AndroidSDKLocator.locate(refresh: refresh)
        self.lookup = lookup
        await discovery.refresh()
        if let sdk = lookup.sdk {
            avds = await AVDCatalog.list(sdk: sdk)
        }
    }
}
