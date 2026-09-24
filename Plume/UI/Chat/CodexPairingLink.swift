import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

/// Same phone setup route used by the installed ChatGPT desktop app. The
/// opaque pairingCode belongs in the URL; manualPairingCode is for computers.
nonisolated enum CodexPairingLink {
    static func url(code: String, expiresAt: Date, claimed: Bool = false, now: Date = Date()) -> URL? {
        guard !claimed, expiresAt > now, !code.isEmpty else { return nil }
        var components = URLComponents(string: "https://chatgpt.com/codex/pair")!
        components.queryItems = [URLQueryItem(name: "pairing_code", value: code)]
        // URLSearchParams interprets an unescaped plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// Core Image keeps sharp module boundaries; the view adds a white quiet zone.
enum CodexPairingQRRenderer {
    static func image(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Render once per pairing link, not on each tick of the expiry label.
struct CodexPairingQRCode: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        // Keep a concrete view mounted before the async task sets `image`.
        // A Group containing only an absent conditional image can disappear
        // before its task runs, leaving a permanently empty QR-sized space.
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .accessibilityLabel("Scan this pairing code with your phone to connect ChatGPT")
            } else if failed {
                Text("QR code unavailable. Use Copy Pairing Link.")
                    .font(.caption)
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(12)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 180, height: 180)
        .fixedSize()
        .clipShape(.rect(cornerRadius: 8))
        .plumeID("codex-pairing-qr", value: "\(image != nil ? "ready" : failed ? "failed" : "loading"); characters=\(url.absoluteString.count)")
        .task(id: url) {
            image = CodexPairingQRRenderer.image(for: url)
            failed = image == nil
        }
    }
}
