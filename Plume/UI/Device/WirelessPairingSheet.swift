import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairs a phone over Wireless debugging, by QR code or pairing code, and hands back the
/// device once adb lists it ready. The presenter dismisses the sheet.
struct WirelessPairingSheet: View {
    let onConnected: (PhysicalDevice) -> Void

    private enum Mode: String, CaseIterable {
        case qrCode
        case pairingCode

        var title: String {
            switch self {
            case .qrCode: "QR Code"
            case .pairingCode: "Pairing Code"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pairing = WirelessPairing()
    @State private var mode = Mode.qrCode
    @State private var code = ""
    @State private var connectAddress = ""
    /// Latched once shown, so a phone appearing later never pulls the field from under typing.
    @State private var entersAddressManually = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair over Wi-Fi").font(.title3.weight(.semibold))
            Picker("Pairing method", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .plumeID(AccessibilityID.wirelessPairingModePicker, value: mode.rawValue, setValue: { raw in
                if let picked = Mode(rawValue: raw) { mode = picked }
            })
            switch mode {
            case .qrCode: qrContent
            case .pairingCode: codeContent
            }
            status
            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .plumeID(AccessibilityID.wirelessPairingCancelButton, invoke: close)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { pairing.startQRCode() }
        .onDisappear { pairing.cancel() }
        .onChange(of: mode) {
            if mode == .qrCode { pairing.startQRCode() } else { startCodeMode() }
        }
        .onChange(of: pairing.phase) {
            switch pairing.phase {
            case .connected(let device): onConnected(device)
            case .failed where mode == .pairingCode: pairing.startBrowsing()
            default: break
            }
        }
        .onChange(of: pairing.browsing) {
            if pairing.browsing == .unavailable || pairing.browsing == .nothingFound { entersAddressManually = true }
        }
    }

    @ViewBuilder
    private var qrContent: some View {
        if pairing.phase == .mdnsUnavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("adb can't discover devices on this network, so it would never see the QR code scanned. Pair with a code instead.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use a Pairing Code") { mode = .pairingCode }
                    .plumeID(AccessibilityID.wirelessPairingUseCodeButton) { mode = .pairingCode }
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                PairingQRCode(payload: pairing.qr.payload)
                instructions(
                    "On the device, open Settings ▸ Developer options ▸ Wireless debugging ▸ Pair device with QR code, then scan this code."
                )
            }
        }
    }

    private var codeContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            instructions(
                "On the device, open Settings ▸ Developer options ▸ Wireless debugging ▸ Pair device with pairing code, then enter what it shows."
            )
            pairingServiceList
            if entersAddressManually {
                TextField("IP address & port", text: $pairing.pairingAddress, prompt: Text("192.168.1.20:37123"))
                    .textFieldStyle(.roundedBorder)
                    .plumeID(AccessibilityID.wirelessPairingAddressField, value: pairing.pairingAddress, setValue: { pairing.pairingAddress = $0 })
            } else {
                Button("Enter address manually") { entersAddressManually = true }
                    .buttonStyle(.link)
                    .plumeID(AccessibilityID.wirelessPairingManualAddressButton, invoke: { entersAddressManually = true })
            }
            TextField("Wi-Fi pairing code", text: $code, prompt: Text("Wi-Fi pairing code"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) { forgetPairing() }
                .onSubmit(pairWithCode)
                .plumeID(AccessibilityID.wirelessPairingCodeField, value: code, setValue: { code = $0 })
            Button("Pair", action: pairWithCode)
                .keyboardShortcut(pairing.returnKeyAction == .pair ? .defaultAction : nil)
                .plumeID(AccessibilityID.wirelessPairingPairButton, invoke: pairWithCode)
                .disabled(isBusy || pairing.pairingAddress.isEmpty || code.isEmpty || pairing.returnKeyAction != .pair)
        }
        .onChange(of: pairing.pairingAddress) { forgetPairing() }
    }

    @ViewBuilder
    private var pairingServiceList: some View {
        switch pairing.browsing {
        case .searching where pairing.pairingServices.isEmpty:
            progress("Looking for a device showing its pairing code…")
        case .unavailable:
            hint("adb can't discover devices on this network. Enter the IP address & port the pairing dialog shows.")
        case .nothingFound where pairing.pairingServices.isEmpty:
            hint("No device found. On the device, open Wireless debugging ▸ Pair device with pairing code, or enter the IP address & port it shows.")
        default:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pairing.pairingServices, id: \.self) { service in
                    pairingServiceRow(service)
                }
            }
        }
    }

    private func pairingServiceRow(_ service: ADBMDNSService) -> some View {
        let selected = pairing.pairingAddress == service.address
        return Button { pairing.select(service) } label: {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pairing.displayName(of: service))
                    Text(service.address).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .plumeID(
            AccessibilityID.wirelessPairingServiceRow, label: service.instance, value: selected ? "selected" : nil,
            invoke: { pairing.select(service) }
        )
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .plumeID(AccessibilityID.wirelessPairingBrowseStatus, value: text)
    }

    private var connectAddressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enter the IP address & port shown on the phone's Wireless debugging screen.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("IP address & port", text: $connectAddress, prompt: Text(connectAddressPrompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitConnectAddress)
                .plumeID(AccessibilityID.wirelessPairingConnectAddressField, value: connectAddress, setValue: { connectAddress = $0 })
        }
    }

    /// The phone listens on the pairing dialog's host, on another port.
    private var connectAddressPrompt: String {
        let host = ADBWireless.address(pairing.pairingAddress).map(ADBWireless.host(of:)) ?? "192.168.1.20"
        return "\(host):port"
    }

    private func instructions(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
            Text("The device and this Mac must be on the same Wi-Fi network.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        switch pairing.phase {
        case .idle, .mdnsUnavailable, .connected:
            EmptyView()
        case .waitingForScan:
            progress("Waiting for the device to scan the code…")
        case .pairing:
            progress("Pairing…")
        case .connecting:
            progress("Paired. Connecting…")
        case .pairedNotConnected(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .plumeID(AccessibilityID.wirelessPairingStatus, value: "paired: \(message)")
                connectAddressField
                Button("Connect", action: connectToAddress)
                    .keyboardShortcut(.defaultAction)
                    .plumeID(AccessibilityID.wirelessPairingConnectButton, invoke: connectToAddress)
                    .disabled(connectAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .plumeID(AccessibilityID.wirelessPairingStatus, value: "failed: \(message)")
                if mode == .qrCode {
                    Button("Try Again") { pairing.startQRCode() }
                        .plumeID(AccessibilityID.wirelessPairingRetryButton) { pairing.startQRCode() }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .plumeID(AccessibilityID.wirelessPairingStatus, value: text)
    }

    private var isBusy: Bool {
        pairing.phase == .pairing || pairing.phase == .connecting
    }

    private func pairWithCode() {
        guard !isBusy, pairing.returnKeyAction == .pair else { return }
        pairing.pair(address: pairing.pairingAddress, code: code)
    }

    private func startCodeMode() {
        pairing.cancel()
        pairing.startBrowsing()
    }

    private func submitConnectAddress() {
        switch pairing.returnKeyAction {
        case .connect: connectToAddress()
        case .pair: pairWithCode()
        }
    }

    /// A changed pairing address or code means pairing again, so Pair takes Return back.
    private func forgetPairing() {
        if pairing.returnKeyAction == .connect { startCodeMode() }
    }

    private func connectToAddress() {
        guard !isBusy, !connectAddress.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pairing.connect(address: connectAddress)
    }

    private func close() {
        pairing.cancel()
        dismiss()
    }
}

/// Rendered once per payload, and scaled without smoothing so the modules stay sharp.
private struct PairingQRCode: View {
    let payload: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                    .accessibilityLabel("Scan this code from Wireless debugging on the device")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(.rect(cornerRadius: 8))
        .plumeID(AccessibilityID.wirelessPairingQRCode, value: image == nil ? "loading" : payload)
        .task(id: payload) {
            image = nil
            let cgImage = await Task.detached(priority: .userInitiated) { [payload] in Self.render(payload) }.value
            image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    nonisolated private static let context = CIContext()

    nonisolated private static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
