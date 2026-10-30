import Foundation
import Testing
@testable import Plume

struct DevicesArgumentTests {
    @Test func parsesClaim() throws {
        #expect(try Devices.parse(["claim"]) == .claim(serial: nil, kind: .emulator, form: nil, owner: nil, ttl: 3600, json: false))
        #expect(try Devices.parse(["claim", "R5", "--kind=any", "--form", "tablet", "--owner=ci", "--ttl=60", "--json"])
            == .claim(serial: "R5", kind: .any, form: .tablet, owner: "ci", ttl: 60, json: true))
    }

    @Test func rejectsBadClaims() {
        for arguments in [
            ["claim", "--kind=tv"], ["claim", "--form=watch"], ["claim", "--ttl=0"],
            ["claim", "--ttl=1h"], ["claim", "--owner="], ["claim", "--owner"], ["claim", "a", "b"], ["claim", "--bogus"],
        ] {
            #expect(throws: Devices.UsageError.self, "\(arguments)") { try Devices.parse(arguments) }
        }
    }

    @Test func parsesTheRest() throws {
        #expect(try Devices.parse(["release", "R5", "--force"]) == .release(serial: "R5", mine: false, owner: nil, force: true))
        #expect(try Devices.parse(["release", "--mine", "--owner", "x"]) == .release(serial: nil, mine: true, owner: "x", force: false))
        #expect(try Devices.parse(["renew", "R5", "--ttl=30"]) == .renew(serial: "R5", owner: nil, ttl: 30))
        #expect(try Devices.parse(["installed", "R5", "main"]) == .installed(serial: "R5", branch: "main"))
        #expect(try Devices.parse(["ls", "--json"]) == .list(json: true))
        #expect(try Devices.parse(["list"]) == .list(json: false))
        #expect(try Devices.parse(["prune"]) == .prune)
        #expect(try Devices.parse([]) == .help)
        #expect(try Devices.parse(["--help"]) == .help)
    }

    @Test func rejectsBadReleasesAndOthers() {
        for arguments in [["release"], ["release", "R5", "--mine"], ["renew"], ["installed"], ["installed", "a", "b", "c"],
                          ["ls", "x"], ["prune", "x"], ["frobnicate"]] {
            #expect(throws: Devices.UsageError.self, "\(arguments)") { try Devices.parse(arguments) }
        }
    }

    // MARK: Owners

    @Test func ownerFlagWinsThenTheTabThenTheWorktree() throws {
        let env = FakeDeviceEnvironment()
        let tab = UUID()
        let inTab = ["PLUME_TAB_ID": tab.uuidString, "PLUME_SOCKET": "/app/cli.sock"]
        #expect(try Devices.claimant(ownerFlag: "ci", environment: inTab, devices: env).owner == .label("ci"))
        let tabClaimant = try Devices.claimant(ownerFlag: nil, environment: inTab, devices: env)
        #expect(tabClaimant == DeviceClaimant(owner: .tab(id: tab, app: "/app/cli.sock"), worktree: "/repo/wt", branch: "feature"))
        #expect(try Devices.claimant(ownerFlag: nil, environment: ["PLUME_TAB_ID": tab.uuidString], devices: env).owner == .label("/repo/wt"))
        env.owner = nil
        #expect(throws: CLIFailure.self) { try Devices.claimant(ownerFlag: nil, environment: [:], devices: env) }
    }

    // MARK: main

    struct Run {
        let env = FakeDeviceEnvironment()
        let app = FakeDeviceAppClient()
        let store: DeviceRegistryStore
        init() throws { store = try makeDeviceStore() }

        func callAsFunction(_ arguments: [String], environment: [String: String] = [:]) -> (code: Int32, console: BufferConsole) {
            let console = BufferConsole()
            let code = Devices.main(arguments, environment: environment, console: console, devices: env, store: store, app: app)
            return (code, console)
        }
    }

    @Test func claimPrintsOnlyTheSerialOnStdout() throws {
        let run = try Run()
        run.env.connect("emulator-5554", avd: "Pixel_8")
        let (code, console) = run(["claim"])
        #expect(code == 0)
        #expect(console.stdout == "emulator-5554\n")
        #expect(console.stderr == "==> claimed emulator-5554 (Pixel_8)\n")
    }

    @Test func claimingFromATabShowsTheDeviceThereAndRecordsTheTab() throws {
        let run = try Run()
        run.env.connect("emulator-5554", avd: "Pixel_8")
        let caller = UUID()
        let deviceTab = UUID()
        run.app.reply = { _ in CLIResponse(ok: true, tabID: deviceTab, created: true) }
        let (code, console) = run(["claim"], environment: ["PLUME_TAB_ID": caller.uuidString, "PLUME_SOCKET": "/app/cli.sock"])

        #expect(code == 0)
        #expect(console.stdout == "emulator-5554\n")
        #expect(run.app.sent.map(\.socket) == ["/app/cli.sock"])
        #expect(run.app.sent.first?.request == .showDevice(.init(tabID: caller, kind: .emulator, serial: "emulator-5554", avdID: "Pixel_8")))
        let lease = try #require(try run.store.load { _ in }.devices["emulator-5554"])
        #expect(lease.deviceTabID == deviceTab)
        #expect(lease.deviceTabCreatedByClaim)

        run.app.reply = { _ in CLIResponse(ok: true, tabID: deviceTab, created: false) }
        #expect(run(["claim"], environment: ["PLUME_TAB_ID": caller.uuidString, "PLUME_SOCKET": "/app/cli.sock"]).code == 0)
        #expect(try run.store.load { _ in }.devices["emulator-5554"]?.deviceTabCreatedByClaim == true)
    }

    @Test func aDeviceTabThatFailsToOpenStillClaims() throws {
        let run = try Run()
        run.env.connect("R5")
        run.app.reply = { _ in throw CLISocket.ClientError.unreachable("gone") }
        let (code, console) = run(["claim", "R5"], environment: ["PLUME_TAB_ID": UUID().uuidString, "PLUME_SOCKET": "/app/cli.sock"])

        #expect(code == 0)
        #expect(console.stdout == "R5\n")
        #expect(console.stderr.contains("couldn't open a device tab: Plume isn't running (gone)"))
        #expect(try run.store.load { _ in }.devices["R5"]?.deviceTabID == nil)
        #expect(run(["claim", "R5", "--owner=ci"]).code == 2)
        #expect(run.app.sent.count == 1)
    }

    @Test func claimJSON() throws {
        let run = try Run()
        run.env.connect("R5")
        let (code, console) = run(["claim", "R5", "--json", "--owner=ci"])
        #expect(code == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(console.stdout.utf8)) as? [String: Any])
        #expect(object["serial"] as? String == "R5")
        #expect(object["kind"] as? String == "physical")
        #expect(object["reused"] as? Bool == false)
        #expect((object["owner"] as? [String: String]) == ["label": "ci"])
    }

    @Test func exitCodesFollowDevicePool() throws {
        let run = try Run()
        run.env.connect("R5")
        #expect(run(["claim", "R5", "--owner=a"]).code == 0)
        let conflict = run(["claim", "R5", "--owner=b"])
        #expect(conflict.code == 2)
        #expect(conflict.console.stderr.contains("R5 is leased by another owner"))
        #expect(conflict.console.stdout.isEmpty)
        let exhausted = run(["claim", "--kind=physical", "--owner=b"])
        #expect(exhausted.code == 3)
        #expect(exhausted.console.stderr.contains("held by a"))
        let usage = run(["claim", "--kind=tv"])
        #expect(usage.code == 1)
        #expect(usage.console.stderr.contains("usage: plume devices"))
        #expect(run(["renew", "R9", "--owner=a"]).code == 1)
    }

    @Test func releaseRenewInstalledAndList() throws {
        let run = try Run()
        run.env.connect("R5")
        run.env.forms["R5"] = .phone
        #expect(run(["claim", "R5"]).code == 0)
        #expect(run(["renew", "R5", "--ttl=120"]).console.stdout == "renewed R5 for 120s\n")
        #expect(run(["installed", "R5"]).console.stdout == "recorded feature on R5\n")
        let list = run(["ls"]).console.stdout
        #expect(list.contains("R5"))
        #expect(list.contains("held by /repo/wt (branch feature), expires in 2m"))
        #expect(list.contains("installed: feature"))
        #expect(run(["release", "--mine"]).console.stdout == "released R5\n")
        #expect(run(["release", "R5"]).console.stdout == "R5 was not leased\n")
        #expect(run(["ls"]).console.stdout.contains("free"))
    }

    @Test func listJSONHasEveryRow() throws {
        let run = try Run()
        run.env.connect("emulator-5554", avd: "Pixel_8")
        let (code, console) = run(["list", "--json"])
        #expect(code == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(console.stdout.utf8)) as? [String: Any])
        let rows = try #require(object["devices"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["avd"] as? String == "Pixel_8")
        #expect(rows.first?["state"] as? String == "device")
    }

    @Test func helpGoesToStdout() throws {
        let run = try Run()
        let (code, console) = run(["help"])
        #expect(code == 0)
        #expect(console.stdout.hasPrefix("usage: plume devices"))
    }
}
