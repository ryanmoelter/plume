import EmulatorControl
import SwiftUI

/// A live emulator with its controls. Depends only on the session, so any
/// container can host it.
struct EmulatorDeviceView: View {
    let session: EmulatorSession
    @State private var confirmingShutDown = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                EmulatorSurface(session: session)
                    .plumeID(AccessibilityID.emulatorSurface, value: stateDescription)
                overlay
            }
        }
        .confirmationDialog(
            "Shut down \(session.displayName ?? "this emulator")?",
            isPresented: $confirmingShutDown
        ) {
            Button("Shut Down", role: .destructive) { session.shutDownEmulator() }
        } message: {
            Text("Anything else using it, such as an agent's adb connection, loses it too.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Text(session.displayName ?? session.avdID ?? "Emulator")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.leading, 8)
            Spacer(minLength: 8)
            Group {
                button("arrow.uturn.backward", "Back", AccessibilityID.emulatorBackButton) { session.press(.back) }
                button("circle", "Home", AccessibilityID.emulatorHomeButton) { session.press(.home) }
                button("square.on.square", "Overview", AccessibilityID.emulatorOverviewButton) { session.press(.overview) }
                Divider().frame(height: 14).padding(.horizontal, 4)
                button("rotate.left", "Rotate Left", AccessibilityID.emulatorRotateLeftButton) { session.rotate(clockwise: false) }
                button("rotate.right", "Rotate Right", AccessibilityID.emulatorRotateRightButton) { session.rotate(clockwise: true) }
                Divider().frame(height: 14).padding(.horizontal, 4)
                button("speaker.minus", "Volume Down", AccessibilityID.emulatorVolumeDownButton) { session.press(.volumeDown) }
                button("speaker.plus", "Volume Up", AccessibilityID.emulatorVolumeUpButton) { session.press(.volumeUp) }
                button("power", "Power", AccessibilityID.emulatorPowerButton) { session.press(.power) }
            }
            .disabled(!session.isConnected)
            Menu {
                Button("Change Device…") { session.changeDevice() }
                    .plumeID(AccessibilityID.emulatorChangeDeviceMenuItem)
                Button("Shut Down Emulator…") { confirmingShutDown = true }
                    .plumeID(AccessibilityID.emulatorShutDownMenuItem)
                    .disabled(!session.isConnected)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .plumeID(AccessibilityID.emulatorMoreMenu)
        }
        .padding(.vertical, 4)
    }

    private func button(_ symbol: String, _ help: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .plumeID(id, invoke: action)
    }

    @ViewBuilder
    private var overlay: some View {
        switch session.state {
        case .connected, .needsDevice:
            EmptyView()
        case .locating, .connecting:
            ProgressView()
                .controlSize(.small)
        case .booting:
            status("Booting \(session.displayName ?? "the emulator")…", showsProgress: true)
        case .notRunning:
            status("\(session.displayName ?? "This emulator") isn't running.") {
                Button("Boot") { session.bootChosenDevice() }
                    .plumeID(AccessibilityID.emulatorBootButton)
            }
        case .disconnected(let reason):
            status("Lost the connection to the emulator.", detail: reason) {
                Button("Reconnect") { session.locate() }
                    .plumeID(AccessibilityID.emulatorReconnectButton)
            }
        case .failed(let reason):
            status("The emulator could not start.", detail: reason) {
                Button("Try Again") { session.bootChosenDevice() }
                    .plumeID(AccessibilityID.emulatorBootButton)
            }
        }
    }

    private func status(
        _ title: String,
        detail: String? = nil,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 10) {
            if showsProgress { ProgressView().controlSize(.small) }
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
            HStack { actions() }
            Button("Change Device…") { session.changeDevice() }
                .buttonStyle(.link)
                .plumeID(AccessibilityID.emulatorChangeDeviceButton)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var stateDescription: String {
        switch session.state {
        case .needsDevice: "needsDevice"
        case .locating: "locating"
        case .notRunning: "notRunning"
        case .booting: "booting"
        case .connecting: "connecting"
        case .connected: session.isStreaming ? "streaming" : "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
    }
}
