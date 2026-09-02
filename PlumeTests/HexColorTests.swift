import Testing
import SwiftUI
@testable import Plume

struct HexColorTests {
    @Test func parsesSixDigitHex() {
        #expect(Color(hex: "ccc2ba") != nil)
    }

    @Test func parsesSixDigitHexWithHashPrefix() {
        #expect(Color(hex: "#ccc2ba") != nil)
    }

    @Test func parsesThreeDigitHex() {
        #expect(Color(hex: "abc") != nil)
    }

    @Test func parsesThreeDigitHexWithHashPrefix() {
        #expect(Color(hex: "#abc") != nil)
    }

    @Test func rejectsWrongLength() {
        #expect(Color(hex: "abcd") == nil)
        #expect(Color(hex: "ab") == nil)
        #expect(Color(hex: "") == nil)
        #expect(Color(hex: "#") == nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(Color(hex: "zzzzzz") == nil)
        #expect(Color(hex: "zzz") == nil)
    }
}

/// The component parse behind `Color(hex:)`, and the contrast math the theme
/// accents use to reject a hue that would be unreadable.
struct HexRGBTests {
    @Test func parsesComponents() throws {
        let color = try #require(HexRGB(hex: "#4080c0"))
        #expect(abs(color.red - 0x40 / 255.0) < 0.001)
        #expect(abs(color.green - 0x80 / 255.0) < 0.001)
        #expect(abs(color.blue - 0xc0 / 255.0) < 0.001)
    }

    @Test func rejectsWhatColorRejects() {
        #expect(HexRGB(hex: "zzzzzz") == nil)
        #expect(HexRGB(hex: "abcd") == nil)
        #expect(HexRGB(hex: "") == nil)
    }

}
