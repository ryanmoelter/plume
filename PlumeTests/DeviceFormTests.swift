import Foundation
import Testing
@testable import Plume

struct DeviceFormTests {
    @Test func overrideWinsOverPhysical() {
        let size = "Physical size: 1080x2400\nOverride size: 1600x2560\n"
        #expect(DeviceForm.wmValue(size) == "1600x2560")
        #expect(DeviceForm.wmValue("Physical density: 420\n") == "420")
        #expect(DeviceForm.wmValue("error: closed\n") == nil)
    }

    @Test func linesAfterOverrideAreIgnored() {
        #expect(DeviceForm.wmValue("Override density: 320\nPhysical density: 480\n") == "320")
    }

    /// 1080 px at 420 dpi is 411 dp; 1600 px at 320 dpi is 800 dp.
    @Test func smallestWidthPicksThePhoneOrTablet() {
        let phone = DeviceForm.smallestWidthDP(wmSize: "Physical size: 1080x2400", wmDensity: "Physical density: 420")
        #expect(phone == 411)
        #expect(DeviceForm.classify(smallestWidthDP: phone) == .phone)
        let tablet = DeviceForm.smallestWidthDP(wmSize: "Physical size: 2560x1600", wmDensity: "Physical density: 320")
        #expect(tablet == 800)
        #expect(DeviceForm.classify(smallestWidthDP: tablet) == .tablet)
        #expect(DeviceForm.classify(smallestWidthDP: 600) == .tablet)
        #expect(DeviceForm.classify(smallestWidthDP: nil) == nil)
    }

    @Test func unreadableWmOutputHasNoWidth() {
        #expect(DeviceForm.smallestWidthDP(wmSize: "", wmDensity: "Physical density: 420") == nil)
        #expect(DeviceForm.smallestWidthDP(wmSize: "Physical size: 1080x2400", wmDensity: "Physical density: 0") == nil)
        #expect(DeviceForm.smallestWidthDP(wmSize: "Physical size: 1080", wmDensity: "Physical density: 420") == nil)
    }

    @Test func avdConfigClassifies() {
        let phone = "hw.lcd.width=1080\nhw.lcd.height=2400\nhw.lcd.density=420\n"
        #expect(DeviceForm.avdForm(configINI: phone) == .phone)
        let tablet = "hw.lcd.width = 2560\nhw.lcd.height = 1600\nhw.lcd.density = 320\n"
        #expect(DeviceForm.avdForm(configINI: tablet) == .tablet)
        #expect(DeviceForm.avdForm(configINI: phone + "hw.sensor.hinge=yes\n") == .foldable)
        #expect(DeviceForm.avdForm(configINI: "hw.sensor.hinge=YES\n") == .foldable)
        #expect(DeviceForm.avdForm(configINI: "avd.ini.displayname=X\n") == nil)
    }

    @Test func foldableModelNames() {
        #expect(DeviceForm.modelLooksFoldable("Pixel Fold"))
        #expect(DeviceForm.modelLooksFoldable("SM-F731U Galaxy Z Flip5"))
        #expect(!DeviceForm.modelLooksFoldable("Pixel 8"))
        let size = "Physical size: 1080x2092", density = "Physical density: 420"
        #expect(DeviceForm.liveForm(wmSize: size, wmDensity: density, model: "Pixel Fold") == .foldable)
        #expect(DeviceForm.liveForm(wmSize: size, wmDensity: density, model: nil) == .phone)
    }
}
