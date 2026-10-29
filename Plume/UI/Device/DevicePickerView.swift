import SwiftUI

/// Lists physical devices and running emulators to show, AVDs to boot, and remote devices to
/// reserve. Discovery runs only while this view is on screen.
struct DevicePickerView: View {
    let onConnect: (PhysicalDevice) -> Void
    let onAttach: (RunningEmulator) -> Void
    let onBoot: (AVD) -> Void
    let onReserve: (RemoteDeviceModel, String) -> Void

    @State private var lookup: AndroidSDKLookup?
    @State private var avds: [AVD] = []
    @State private var remoteSearch = ""
    @Environment(\.openSettings) private var openSettings
    private var discovery: EmulatorDiscovery { .shared }
    private var physicalDiscovery: PhysicalDeviceDiscovery { .shared }
    private var remoteCatalog: RemoteDeviceCatalog { .shared }

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
        .task {
            await remoteCatalog.loadIfNeeded()
            await remoteCatalog.loadModels()
        }
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
            physicalSection(hasADB: sdk.adbURL != nil)
            remoteSection
            emulatorSections(hasEmulator: sdk.emulatorURL != nil)
        }
    }

    /// Remote devices this app reserved are adb devices too; they show as their own tabs instead.
    private var usbDevices: [PhysicalDevice] {
        let remoteSerials = DeviceSessionManager.shared.remoteSerials
        return physicalDiscovery.devices.filter { !remoteSerials.contains($0.serial) }
    }

    private func physicalSection(hasADB: Bool) -> some View {
        section("Devices") {
            if !hasADB {
                placeholder("adb wasn't found. Install Android SDK Platform-Tools with Android Studio's SDK Manager.")
            } else if usbDevices.isEmpty {
                placeholder("No devices are connected. Connect one over USB with USB debugging on.")
            }
            ForEach(usbDevices) { device in
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

    private var remoteSection: some View {
        section("Remote Devices") {
            switch remoteCatalog.availability {
            case .loading:
                ProgressView().controlSize(.small).padding(10)
            case .cliMissing:
                remotePlaceholder("Reserve a device from Google's lab with the android command-line tool. Install it, then sign in from Settings ▸ Integrations.")
            case .signedOut:
                remotePlaceholder("Sign in to the android command-line tool in Settings ▸ Integrations to reserve a remote device.")
            case .failed(let message):
                remotePlaceholder(message)
            case .signedIn:
                remoteModels
            }
        }
    }

    @ViewBuilder
    private var remoteModels: some View {
        if let project = remoteCatalog.selectedProject {
            VStack(alignment: .leading, spacing: 8) {
                if remoteCatalog.projects.count > 1 {
                    Picker("Project", selection: Binding(
                        get: { project },
                        set: { newValue in
                            remoteCatalog.selectedProject = newValue
                            Task { await remoteCatalog.loadModels() }
                        }
                    )) {
                        ForEach(remoteCatalog.projects, id: \.self) { Text($0).tag($0) }
                    }
                    .plumeID(AccessibilityID.devicePickerRemoteProjectPicker, value: project)
                } else {
                    Text("Project: \(project)").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Search models", text: $remoteSearch)
                    .textFieldStyle(.roundedBorder)
                    .plumeID(AccessibilityID.devicePickerRemoteSearch, value: remoteSearch)
                Text("Reservations are billed and last 15 minutes unless extended. Closing the tab or quitting Plume ends one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            if remoteCatalog.isLoadingModels {
                ProgressView().controlSize(.small).padding(10)
            } else if let error = remoteCatalog.modelsError {
                placeholder(error)
            } else if filteredModels.isEmpty {
                placeholder(remoteCatalog.models.isEmpty ? "No models are available." : "No models match.")
            }
            LazyVStack(spacing: 0) {
                ForEach(filteredModels) { model in
                    row(
                        title: model.displayName,
                        detail: "\(model.manufacturer) · \(model.id)",
                        action: "Reserve",
                        id: AccessibilityID.devicePickerRemoteRow,
                        label: model.id
                    ) { onReserve(model, project) }
                }
            }
        } else {
            remotePlaceholder("No Google Cloud project is ready for device streaming.")
        }
    }

    private var filteredModels: [RemoteDeviceModel] {
        let query = remoteSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return remoteCatalog.models }
        return remoteCatalog.models.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.manufacturer.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func remotePlaceholder(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings", action: openIntegrationsSettings)
                .plumeID(AccessibilityID.devicePickerRemoteSettingsButton, invoke: openIntegrationsSettings)
        }
        .padding(10)
    }

    private func openIntegrationsSettings() {
        UserDefaults.standard.set(SettingsPane.integrations.rawValue, forKey: SettingsPane.selectionKey)
        openSettings()
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
