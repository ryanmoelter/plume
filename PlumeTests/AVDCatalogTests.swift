import Foundation
import Testing
@testable import Plume

struct AVDCatalogTests {
    @Test func listOutputDropsInfoLines() {
        let output = "INFO    | Storing crashdata in: /tmp/x\nINFO | something\nMedium_Phone_API_36\r\nPixel_8\n\n"
        #expect(AVDCatalog.parseListOutput(output) == ["Medium_Phone_API_36", "Pixel_8"])
    }

    @Test func idComesFromIniNameNotDirectory() {
        let avdHome = URL(fileURLWithPath: "/home/.android/avd", isDirectory: true)
        let avd = AVDCatalog.makeAVD(
            id: "Medium_Phone_API_36",
            rootINI: "avd.ini.encoding=UTF-8\npath=/home/.android/avd/Medium_Phone.avd\n",
            configINI: nil,
            avdHome: avdHome
        )
        #expect(avd.id == "Medium_Phone_API_36")
        #expect(avd.directory.path == "/home/.android/avd/Medium_Phone.avd")
    }

    @Test func readsDisplayNameAndLCDSize() {
        let avd = AVDCatalog.makeAVD(
            id: "Pixel_8",
            rootINI: nil,
            configINI: "avd.ini.displayname=Pixel 8\nhw.lcd.width=1080\nhw.lcd.height=2400\n",
            avdHome: URL(fileURLWithPath: "/h", isDirectory: true)
        )
        #expect(avd.displayName == "Pixel 8")
        #expect(avd.lcdSize == CGSize(width: 1080, height: 2400))
        #expect(avd.directory.path == "/h/Pixel_8.avd")
    }

    @Test func missingConfigFallsBackToIdAndNoSize() {
        let avd = AVDCatalog.makeAVD(id: "Pixel_8", rootINI: nil, configINI: nil, avdHome: URL(fileURLWithPath: "/h"))
        #expect(avd.displayName == "Pixel 8")
        #expect(avd.lcdSize == nil)
    }

    @Test func avdHomeHonorsEnvironment() {
        #expect(AVDCatalog.defaultAVDHome(environment: ["ANDROID_AVD_HOME": "/custom"]).path == "/custom")
    }
}
