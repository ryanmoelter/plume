import SwiftUI

/// A live Android device with its controls. Depends only on the session, so any
/// container can host it.
struct AndroidDeviceView: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    let session: DeviceSession
    @State private var confirmingShutDown = false
    @State private var confirmingEndReservation = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                DeviceSurface(session: session)
                    .plumeID(AccessibilityID.deviceSurface, value: stateDescription)
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
        .confirmationDialog(
            "End the reservation for \(session.displayName ?? "this device")?",
            isPresented: $confirmingEndReservation
        ) {
            Button("End Reservation", role: .destructive) { session.endReservation() }
        } message: {
            Text("The device goes back to Google's lab, and anything using it over adb loses it.")
        }
        .alert(
            "Couldn't extend the reservation",
            isPresented: Binding(get: { session.extendError != nil }, set: { if !$0 { session.extendError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.extendError ?? "")
        }
    }

    private var deviceName: String {
        session.displayName ?? session.target?.identifier ?? "Device"
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                identity
                Spacer(minLength: 8)
                controls
            }
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    identity
                    Spacer(minLength: 8)
                }
                HStack(spacing: 2) {
                    Spacer(minLength: 8)
                    controls
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var identity: some View {
        HStack(spacing: 2) {
            Text(deviceName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.leading, 8)
            if session.hasLiveReservation {
                reservationControls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Group {
                button("arrow.uturn.backward", "Back", AccessibilityID.deviceBackButton) { session.press(.back) }
                button("circle", "Home", AccessibilityID.deviceHomeButton) { session.press(.home) }
                button("square.on.square", "Overview", AccessibilityID.deviceOverviewButton) { session.press(.overview) }
                Divider().frame(height: 14).padding(.horizontal, 4)
                // A phone's orientation follows its own sensor and auto-rotate setting, but nobody
                // can turn a lab device. scrcpy's rotate only toggles, so it has no direction.
                if session.isRemote {
                    button("rotate.right", "Rotate", AccessibilityID.deviceRotateButton) { session.rotate(clockwise: true) }
                    Divider().frame(height: 14).padding(.horizontal, 4)
                } else if !session.isPhysical {
                    button("rotate.left", "Rotate Left", AccessibilityID.deviceRotateLeftButton) { session.rotate(clockwise: false) }
                    button("rotate.right", "Rotate Right", AccessibilityID.deviceRotateRightButton) { session.rotate(clockwise: true) }
                    Divider().frame(height: 14).padding(.horizontal, 4)
                }
                button("speaker.minus", "Volume Down", AccessibilityID.deviceVolumeDownButton) { session.press(.volumeDown) }
                button("speaker.plus", "Volume Up", AccessibilityID.deviceVolumeUpButton) { session.press(.volumeUp) }
                button("power", "Power", AccessibilityID.devicePowerButton) { session.press(.power) }
            }
            .disabled(!session.isConnected)
            Menu {
                Button("Change Device…") { session.changeDevice() }
                    .plumeID(AccessibilityID.deviceChangeDeviceMenuItem)
                if session.canEndReservation {
                    Button("End Reservation…") { confirmingEndReservation = true }
                        .plumeID(AccessibilityID.deviceEndReservationMenuItem)
                }
                if !session.isPhysical {
                    Button("Shut Down Emulator…") { confirmingShutDown = true }
                        .plumeID(AccessibilityID.emulatorShutDownMenuItem)
                        .disabled(!session.canShutDownEmulator)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
            .plumeID(AccessibilityID.deviceMoreMenu)
        }
    }

    private var reservationControls: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let minutes = session.reservation?.expiresAt.map { Self.minutesLeft(until: $0, now: context.date) }
                Text(minutes.map { "\($0) min left" } ?? "Reserved")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle((minutes ?? Int.max) < 3 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .plumeID(AccessibilityID.deviceTimeLeft, value: minutes.map(String.init))
            }
            Button(action: extend) {
                if session.isExtending {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("+\(DeviceSession.extendMinutes) min")
                }
            }
            .controlSize(.small)
            .help("Extend the reservation by \(DeviceSession.extendMinutes) minutes")
            .plumeID(AccessibilityID.deviceExtendButton, invoke: extend)
            .disabled(session.isExtending)
            if session.canEndReservation {
                Button("End Reservation…") { confirmingEndReservation = true }
                    .controlSize(.small)
                    .tint(.red)
                    .plumeID(AccessibilityID.deviceEndReservationButton) { confirmingEndReservation = true }
            }
        }
        .padding(.leading, 6)
    }

    private func extend() {
        session.extendReservation()
    }

    /// Rounded up, so "1 min left" shows until the reservation actually ends.
    static func minutesLeft(until expiry: Date, now: Date) -> Int {
        max(0, Int((expiry.timeIntervalSince(now) / 60).rounded(.up)))
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
        case .locating, .connecting, .suspended:
            ProgressView()
                .controlSize(.small)
        case .booting:
            status("Booting \(session.displayName ?? "the emulator")…", showsProgress: true)
        case .notRunning where session.isPhysical:
            status(
                "\(session.displayName ?? "This device") isn't connected.",
                detail: "Connect it over USB and allow USB debugging on the device."
            ) {
                Button("Try Again") { session.locate() }
                    .plumeID(AccessibilityID.deviceRetryButton)
            }
        case .notRunning:
            status("\(session.displayName ?? "This emulator") isn't running.") {
                Button("Boot") { session.bootChosenDevice() }
                    .plumeID(AccessibilityID.emulatorBootButton)
            }
        case .disconnected(let reason):
            status("Lost the connection to the \(session.isPhysical ? "device" : "emulator").", detail: reason) {
                Button("Reconnect") { session.locate() }
                    .plumeID(AccessibilityID.deviceReconnectButton)
            }
        case .failed(let reason):
            status("The emulator could not start.", detail: reason) {
                Button("Try Again") { session.bootChosenDevice() }
                    .plumeID(AccessibilityID.emulatorBootButton)
            }
        case .reserving:
            status(
                "Reserving \(session.displayName ?? "a remote device")…",
                detail: "This may take a minute or two",
                showsProgress: true
            )
        case .reservationEnded:
            status("The reservation for \(session.displayName ?? "this device") ended.") {
                reserveAgainButton
            }
        case .reservationFailed(let reason):
            status("Device Streaming didn't respond as expected.", detail: reason) {
                if session.hasLiveReservation {
                    Button("Try Again") { session.locate() }
                        .plumeID(AccessibilityID.deviceRetryButton)
                } else {
                    reserveAgainButton
                }
            }
        }
    }

    @ViewBuilder
    private var reserveAgainButton: some View {
        if session.remoteDetails?.model != nil {
            Button("Reserve Again") { session.reserveAgain() }
                .plumeID(AccessibilityID.deviceReserveAgainButton)
        }
    }

    private func status(
        _ title: String,
        detail: String? = nil,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsProgress { ProgressView().controlSize(.small) }
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(session.state == .reserving ? "Cancel" : "Change Device…") { session.changeDevice() }
                    .buttonStyle(.bordered)
                    .plumeID(AccessibilityID.deviceChangeDeviceButton)
                actions()
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(20)
        .glassEffect(statusGlass, in: .rect(cornerRadius: 10))
    }

    private var statusGlass: Glass {
        ThemeChrome.background(for: colorScheme).map { Glass.regular.tint($0.opacity(0.5)) } ?? .regular
    }

    private var stateDescription: String {
        switch session.state {
        case .needsDevice: "needsDevice"
        case .locating: "locating"
        case .notRunning: "notRunning"
        case .booting: "booting"
        case .connecting: "connecting"
        case .connected: session.isStreaming ? "streaming" : "connected"
        case .suspended: "suspended"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .reserving: "reserving"
        case .reservationEnded: "reservationEnded"
        case .reservationFailed: "reservationFailed"
        }
    }
}
