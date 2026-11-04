import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairs a phone over Wireless debugging, by QR code or pairing code, and hands back the
/// device once adb lists it ready.
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
    @State private var address = ""
    @State private var code = ""

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
            if mode == .qrCode { pairing.startQRCode() } else { pairing.cancel() }
        }
        .onChange(of: pairing.phase) {
            guard case .connected(let device) = pairing.phase else { return }
            onConnected(device)
            dismiss()
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
            TextField("IP address & port", text: $address, prompt: Text("192.168.1.20:37123"))
                .textFieldStyle(.roundedBorder)
                .plumeID(AccessibilityID.wirelessPairingAddressField, value: address, setValue: { address = $0 })
            TextField("Wi-Fi pairing code", text: $code, prompt: Text("Wi-Fi pairing code"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(pairWithCode)
                .plumeID(AccessibilityID.wirelessPairingCodeField, value: code, setValue: { code = $0 })
            Button("Pair", action: pairWithCode)
                .keyboardShortcut(.defaultAction)
                .plumeID(AccessibilityID.wirelessPairingPairButton, invoke: pairWithCode)
                .disabled(isBusy || address.isEmpty || code.isEmpty)
        }
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
        guard !isBusy else { return }
        pairing.pair(address: address, code: code)
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
        .task(id: payload) { image = Self.render(payload) }
    }

    private static func render(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
