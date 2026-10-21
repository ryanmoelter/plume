import Foundation
import Testing
@testable import Plume

struct LinearStateColorTests {
    private func hex(_ value: String) -> HexRGB { HexRGB(hex: value)! }

    private let mocha: [Int: HexRGB] = [
        1: HexRGB(hex: "f38ba8")!, 2: HexRGB(hex: "a6e3a1")!, 3: HexRGB(hex: "f9e2af")!,
        4: HexRGB(hex: "89b4fa")!, 5: HexRGB(hex: "f5c2e7")!, 6: HexRGB(hex: "94e2d5")!,
    ]

    private func slot(_ color: String, among palette: [Int: HexRGB]) -> Int? {
        LinearStateColor.nearestSlot(to: hex(color), among: palette)
    }

    // Expected slots match Linear's default workflow colors.
    @Test(arguments: [
        ("e2e2e2", nil), ("bec2c8", nil), ("95a2b3", nil),
        ("f2c94c", 3), ("5e6ad2", 4), ("fc7840", 1), ("0f7488", 6),
    ] as [(String, Int?)])
    func fallbackSlotsMapLinearDefaults(color: String, expected: Int?) {
        #expect(slot(color, among: LinearStateColor.fallbackSlots) == expected)
    }

    @Test(arguments: [
        ("e2e2e2", nil), ("bec2c8", nil), ("95a2b3", nil),
        ("f2c94c", 3), ("5e6ad2", 4), ("fc7840", 1), ("0f7488", 4),
    ] as [(String, Int?)])
    func aThemedPaletteMapsLinearDefaults(color: String, expected: Int?) {
        #expect(slot(color, among: mocha) == expected)
    }

    @Test func aGrayCandidateIsNeverChosen() {
        var palette = LinearStateColor.fallbackSlots
        palette[3] = hex("808080")
        #expect(slot("f2c94c", among: palette) != 3)
    }

    private typealias OKLab = LinearStateColor.OKLab

    private var darkBackground: HexRGB { hex("1e1e2e") }
    private var darkForeground: HexRGB { hex("cdd6f4") }
    private var lightBackground: HexRGB { hex("ffffff") }
    private var lightForeground: HexRGB { hex("1a1a1a") }

    private func contrastedOnDark(_ color: String) -> HexRGB {
        LinearStateColor.contrasted(hex(color), background: darkBackground, foreground: darkForeground)
    }

    private func contrastedOnLight(_ color: String) -> HexRGB {
        LinearStateColor.contrasted(hex(color), background: lightBackground, foreground: lightForeground)
    }

    @Test func aDimColorStaysReadableOnADarkTheme() {
        let result = OKLab(contrastedOnDark("e2e2e2"))
        let (backgroundL, foregroundL) = (OKLab(darkBackground).l, OKLab(darkForeground).l)
        #expect(result.l >= backgroundL + LinearStateColor.minimumGap - 0.001)
        #expect(result.l <= foregroundL + 0.001)
    }

    @Test func aVeryDarkColorIsLiftedOnADarkTheme() {
        let input = hex("3a2a5a")
        let (backgroundL, foregroundL) = (OKLab(darkBackground).l, OKLab(darkForeground).l)
        let gap = min(LinearStateColor.minimumGap, (foregroundL - backgroundL) / 2)
        let result = OKLab(contrastedOnDark("3a2a5a"))
        #expect(OKLab(input).l < backgroundL + gap)
        #expect(result.l >= backgroundL + gap - 0.001)
        #expect(result.l <= foregroundL + 0.001)
    }

    @Test func aLightColorIsDarkenedOnALightTheme() {
        let (backgroundL, foregroundL) = (OKLab(lightBackground).l, OKLab(lightForeground).l)
        let gap = min(LinearStateColor.minimumGap, (backgroundL - foregroundL) / 2)
        let result = OKLab(contrastedOnLight("f2c94c"))
        #expect(OKLab(hex("f2c94c")).l > backgroundL - gap)
        #expect(result.l <= backgroundL - gap + 0.001)
        #expect(result.l >= foregroundL - 0.001)
    }

    @Test(arguments: ["3a2a5a", "5e6ad2", "fc7840"])
    func contrastKeepsHueAndStaysInGamut(color: String) {
        let before = OKLab(hex(color))
        for result in [contrastedOnDark(color), contrastedOnLight(color)] {
            let after = OKLab(result)
            let drift = abs(atan2(after.b, after.a) - atan2(before.b, before.a))
            #expect(min(drift, 2 * .pi - drift) < 0.15)
            #expect((0...1).contains(result.red))
            #expect((0...1).contains(result.green))
            #expect((0...1).contains(result.blue))
        }
    }

    @Test func aThemeWithNoContrastLeavesTheColorUnchanged() {
        let input = hex("3a2a5a")
        let result = LinearStateColor.contrasted(input, background: hex("808080"), foreground: hex("858585"))
        #expect(result == input)
    }
}
