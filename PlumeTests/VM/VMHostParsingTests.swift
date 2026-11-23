import Foundation
import Testing
@testable import Plume

struct VMHostParsingTests {
    @Test func normalizesMACOctets() {
        #expect(VMHost.normalizeMAC("76:7B:F5:77:06:5D") == "76:7b:f5:77:6:5d")
        #expect(VMHost.normalizeMAC("e2:9a:0f:27:57:00") == "e2:9a:f:27:57:0")
        #expect(VMHost.normalizeMAC("76:7b:f5:77:6:5d") == VMHost.normalizeMAC("76:7b:f5:77:06:5d"))
    }

    static let leases = """
        {
        \tname=ManagedlMachine
        \tip_address=192.168.64.7
        \thw_address=1,e2:9a:f:27:57:55
        \tidentifier=1,e2:9a:f:27:57:55
        \tlease=0x6b03feff
        }
        {
        \tname=ManagedlMachine
        \tip_address=192.168.64.3
        \thw_address=1,76:7b:f5:77:6:5d
        \tidentifier=1,76:7b:f5:77:6:5d
        \tlease=0x6b03f000
        }
        {
        \tname=ManagedlMachine
        \tip_address=192.168.64.9
        \thw_address=1,76:7b:f5:77:6:5d
        \tidentifier=1,76:7b:f5:77:6:5d
        \tlease=0x6b03fdef
        }
        """

    @Test func parsesDHCPLeases() {
        let parsed = VMHost.parseDHCPLeases(Self.leases)
        #expect(parsed.count == 3)
        #expect(parsed.first == .init(ip: "192.168.64.7", mac: "e2:9a:f:27:57:55", expiry: 0x6b03feff))
    }

    @Test func findsTheNewestAddressForAZeroPaddedMAC() {
        #expect(VMHost.ipAddress(forMAC: "76:7b:f5:77:06:5d", leasesText: Self.leases) == "192.168.64.9")
        #expect(VMHost.ipAddress(forMAC: "e2:9a:0f:27:57:55", leasesText: Self.leases) == "192.168.64.7")
        #expect(VMHost.ipAddress(forMAC: "aa:bb:cc:dd:ee:ff", leasesText: Self.leases) == nil)
    }

    static func ioreg(user: String = "admin", onConsole: Bool = true, loginDone: Bool = true, locked: Bool? = nil) -> Data {
        let lock = locked.map { "<key>CGSSessionScreenIsLocked</key>\($0 ? "<true/>" : "<false/>")" } ?? ""
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>IOConsoleLocked</key><false/>
            \t<key>IOConsoleUsers</key>
            \t<array>
            \t\t<dict>
            \t\t\t\(lock)
            \t\t\t<key>kCGSSessionOnConsoleKey</key>\(onConsole ? "<true/>" : "<false/>")
            \t\t\t<key>kCGSSessionUserIDKey</key><integer>501</integer>
            \t\t\t<key>kCGSSessionUserNameKey</key><string>\(user)</string>
            \t\t\t<key>kCGSessionLoginDoneKey</key>\(loginDone ? "<true/>" : "<false/>")
            \t\t</dict>
            \t</array>
            \t<key>IOKitBuildVersion</key><string>Darwin Kernel Version 27.2.0</string>
            </dict>
            </plist>
            """.utf8)
    }

    @Test func readyOnceTheGuestUserIsLoggedInAndUnlocked() {
        #expect(VMHost.consoleIsReady(ioregPlist: Self.ioreg()))
        #expect(VMHost.consoleIsReady(ioregPlist: Self.ioreg(locked: false)))
    }

    @Test func notReadyWhileLockedLoggingInOrAnotherUser() {
        #expect(!VMHost.consoleIsReady(ioregPlist: Self.ioreg(locked: true)))
        #expect(!VMHost.consoleIsReady(ioregPlist: Self.ioreg(loginDone: false)))
        #expect(!VMHost.consoleIsReady(ioregPlist: Self.ioreg(onConsole: false)))
        #expect(!VMHost.consoleIsReady(ioregPlist: Self.ioreg(user: "someone")))
        #expect(!VMHost.consoleIsReady(ioregPlist: Data("not a plist".utf8)))
    }

    @Test func readinessNeedsThisClonesMAC() {
        let console = String(decoding: Self.ioreg(), as: UTF8.self)
        let output = "76:7b:f5:77:06:5d\n" + VMHost.readinessSeparator + "\n" + console
        #expect(VMHost.isReady(readinessOutput: output, mac: "76:7B:F5:77:6:5D"))
        #expect(!VMHost.isReady(readinessOutput: output, mac: "e2:9a:0f:27:57:55"))
        #expect(!VMHost.isReady(readinessOutput: console, mac: "76:7b:f5:77:06:5d"))
    }

    @Test func sshOffersOnlyTheVMKey() {
        let arguments = VMHost.sshArguments(ip: "192.168.64.2", command: "true")
        #expect(arguments.contains("IdentitiesOnly=yes"))
    }

    @Test func readinessShowsTheMACBeforeTheConsoleIsReady() {
        let locked = String(decoding: Self.ioreg(locked: true), as: UTF8.self)
        let output = "76:7b:f5:77:06:5d\n" + VMHost.readinessSeparator + "\n" + locked
        #expect(VMHost.readinessShowsMAC(output, mac: "76:7b:f5:77:6:5d"))
        #expect(!VMHost.readinessShowsMAC(output, mac: "e2:9a:0f:27:57:55"))
        #expect(!VMHost.isReady(readinessOutput: output, mac: "76:7b:f5:77:6:5d"))
    }

    @Test func shutdownChecksTheGuestsMACFirst() {
        #expect(VMHost.shutdownCommand(mac: "76:7B:F5:77:6:5D")
            == "ifconfig | grep -qiF 'ether 76:7b:f5:77:06:5d' && sudo shutdown -h now")
    }
}
