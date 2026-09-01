import Testing
import AppKit
import SwiftUI
@testable import Plume

/// The test host loads the app's resources, so this is a real check that the
/// bundled files register rather than a check on the code path alone.
@MainActor
struct BundledFontsTests {
    @Test func theProseFaceRegistersFromTheBundle() {
        #expect(BundledFonts.isProseAvailable, "\(BundledFonts.prose) did not register from the bundle")
    }

    /// Italics must come from the italic file rather than being synthesized
    /// by slanting the upright.
    @Test func aRealItalicFaceIsAvailable() {
        BundledFonts.registerIfNeeded()
        let members = NSFontManager.shared.availableMembers(ofFontFamily: BundledFonts.prose) ?? []
        let names = members.compactMap { $0.first as? String }
        #expect(names.contains { $0.localizedCaseInsensitiveContains("italic") }, "no italic member in \(names)")
    }

    @Test func registeringTwiceIsHarmless() {
        BundledFonts.registerIfNeeded()
        BundledFonts.registerIfNeeded()
        #expect(BundledFonts.isProseAvailable)
    }
}

/// The chat's prose font resolves to the real family, not a substitute.
@MainActor
struct ChatProseFontTests {
    @Test func proseResolvesAtTheRequestedSize() {
        BundledFonts.registerIfNeeded()
        let font = NSFont(name: BundledFonts.prose, size: 17)
        #expect(font != nil, "\(BundledFonts.prose) did not resolve as an NSFont")
        #expect(font?.pointSize == 17)
        #expect(font?.familyName == BundledFonts.prose)
    }

    /// Libre Baskerville is variable on weight alone — there is no optical
    /// size axis to track, unlike the face this replaced.
    @Test func theWeightAxisIsPresent() {
        BundledFonts.registerIfNeeded()
        let font = NSFont(name: BundledFonts.prose, size: 12)
        let axes = (CTFontCopyVariationAxes(font! as CTFont) as? [[String: Any]]) ?? []
        let tags = axes.compactMap { $0[kCTFontVariationAxisIdentifierKey as String] as? Int }
        let wght = 0x77676874
        #expect(tags.contains(wght), "no wght axis in \(tags)")
    }
}

/// The composer is AppKit, so it takes `NSFont` rather than SwiftUI's `Font`.
/// Emphasis is derived from that descriptor, which is what keeps bold and
/// italic inside the bundled family.
@MainActor
struct ComposerProseFontTests {
    @Test func theComposerBodyFontIsTheBundledFamily() {
        BundledFonts.registerIfNeeded()
        #expect(NSFont.chatProse(ofSize: 15).familyName == BundledFonts.prose)
        #expect(NSFont.chatProse(ofSize: 15).pointSize == 15)
    }

    @Test func italicResolvesWithinTheFamilyRatherThanBeingSynthesized() {
        BundledFonts.registerIfNeeded()
        let base = NSFont.chatProse(ofSize: 15)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        let italic = try? #require(NSFont(descriptor: descriptor, size: 15))

        #expect(italic?.familyName == BundledFonts.prose)
        // A synthesized slant keeps the upright's PostScript name; a real
        // italic face reports its own.
        #expect(italic?.fontName != base.fontName, "italic did not resolve to a distinct face")
    }

    @Test func boldResolvesWithinTheFamily() {
        BundledFonts.registerIfNeeded()
        let base = NSFont.chatProse(ofSize: 15)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.bold)
        let bold = try? #require(NSFont(descriptor: descriptor, size: 15))

        #expect(bold?.familyName == BundledFonts.prose)
        #expect(bold?.fontName != base.fontName, "bold did not resolve to a distinct face")
    }
}

/// The prose font sits on the scroll path — `MarkdownView` asks for it once
/// per block — so resolving it has to stay cheap.
@MainActor
struct ProseFontCostTests {
    /// Guards against reintroducing a system-wide font enumeration behind
    /// `chatProse`. `availableFontFamilies` measured ~0.045ms a call against
    /// ~0.001ms for a font lookup, which is what made scrolling stutter.
    @Test func resolvingProseRepeatedlyStaysCheap() {
        BundledFonts.registerIfNeeded()
        // Warm the cache and the font cache so this times steady state.
        _ = Font.chatProse(size: 15)
        _ = NSFont.chatProse(ofSize: 15)

        let iterations = 2000
        let start = Date()
        for _ in 0..<iterations {
            _ = Font.chatProse(size: 15)
            _ = NSFont.chatProse(ofSize: 15)
        }
        let msEach = Date().timeIntervalSince(start) * 1000 / Double(iterations)

        // An enumeration-backed check lands around 0.045ms per call, so this
        // threshold is loose enough for a busy machine and still far below a
        // regression.
        #expect(msEach < 0.02, "prose font resolution cost \(msEach) ms per call")
    }
}
