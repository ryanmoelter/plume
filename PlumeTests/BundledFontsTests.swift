import Testing
import AppKit
@testable import Plume

/// The test host loads the app's resources, so this is a real check that the
/// bundled files register rather than a check on the code path alone.
@MainActor
struct BundledFontsTests {
    @Test func newsreaderRegistersFromTheBundle() {
        #expect(BundledFonts.isNewsreaderAvailable, "Newsreader did not register from the bundle")
    }

    /// Italics must come from the italic file rather than being synthesized
    /// by slanting the upright.
    @Test func aRealItalicFaceIsAvailable() {
        BundledFonts.registerIfNeeded()
        let members = NSFontManager.shared.availableMembers(ofFontFamily: BundledFonts.newsreader) ?? []
        let names = members.compactMap { $0.first as? String }
        #expect(names.contains { $0.localizedCaseInsensitiveContains("italic") }, "no italic member in \(names)")
    }

    @Test func registeringTwiceIsHarmless() {
        BundledFonts.registerIfNeeded()
        BundledFonts.registerIfNeeded()
        #expect(BundledFonts.isNewsreaderAvailable)
    }
}

/// The chat's prose font resolves to the real family, not a substitute.
@MainActor
struct ChatProseFontTests {
    @Test func proseResolvesToNewsreaderAtTheRequestedSize() {
        BundledFonts.registerIfNeeded()
        let font = NSFont(name: BundledFonts.newsreader, size: 17)
        #expect(font != nil, "Newsreader did not resolve as an NSFont")
        #expect(font?.pointSize == 17)
        #expect(font?.familyName == BundledFonts.newsreader)
    }

    /// `opsz` tracks the point size, so the same family at two sizes yields
    /// genuinely different faces rather than one scaled outline.
    @Test func theOpticalSizeAxisIsPresent() {
        BundledFonts.registerIfNeeded()
        let font = NSFont(name: BundledFonts.newsreader, size: 12)
        let axes = (CTFontCopyVariationAxes(font! as CTFont) as? [[String: Any]]) ?? []
        let tags = axes.compactMap { $0[kCTFontVariationAxisIdentifierKey as String] as? Int }
        // 'opsz' and 'wght' as four-character codes.
        let opsz = Int(truncating: 0x6F70737A as NSNumber)
        let wght = Int(truncating: 0x77676874 as NSNumber)
        #expect(tags.contains(opsz), "no opsz axis in \(tags)")
        #expect(tags.contains(wght), "no wght axis in \(tags)")
    }
}
