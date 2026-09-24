import AppKit
import CoreImage
import Foundation
import Testing
@testable import Plume

struct CodexPairingLinkTests {
    @MainActor @Test func qrImageContainsDecodableSyntheticLink() throws {
        let url = URL(string: "https://chatgpt.com/codex/pair?pairing_code=synthetic%2Bcode")!
        let image = try #require(CodexPairingQRRenderer.image(for: url))
        let data = try #require(image.tiffRepresentation)
        let ciImage = try #require(CIImage(data: data))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(codes == [url.absoluteString])
        #expect(image.size.width == image.size.height)
        #expect(image.size.width > 180)
    }

    @Test func opaquePairingCodeIsEncodedInVerifiedSetupRoute() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let code = "opaque+code/&?=# value"
        let url = try #require(CodexPairingLink.url(code: code, expiresAt: now.addingTimeInterval(60), now: now))
        #expect(url.scheme == "https")
        #expect(url.host == "chatgpt.com")
        #expect(url.path == "/codex/pair")
        #expect(url.fragment == nil)
        #expect(url.absoluteString.contains("%2B"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "pairing_code", value: code)])
    }

    @Test func expiredClaimedAndMissingCodesCannotCreateLinks() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now, now: now) == nil)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now.addingTimeInterval(-1), now: now) == nil)
        #expect(CodexPairingLink.url(code: "code", expiresAt: now.addingTimeInterval(60), claimed: true, now: now) == nil)
        #expect(CodexPairingLink.url(code: "", expiresAt: now.addingTimeInterval(60), now: now) == nil)
    }
}
