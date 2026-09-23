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

/// Render once per pairing link, not on each tick of the expiry label.
struct CodexPairingQRCode: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Scan this pairing code with your phone to connect ChatGPT")
            }
        }
        .frame(width: 180, height: 180)
        .task(id: url) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.absoluteString.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                  let cgImage = CIContext().createCGImage(output, from: output.extent) else {
                image = nil
                return
            }
            image = NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
        }
    }
}
