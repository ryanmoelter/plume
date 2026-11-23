import Foundation
import Testing
@testable import Plume

/// `plume devices` for VMs: parsing, and the requests it sends the app at `PLUME_SOCKET`.
struct VMDevicesTests {
    static let socket = "/app/cli.sock"
    static let environment = ["PLUME_SOCKET": socket]

    static func slot(_ number: Int, _ state: VMSlotState, owner: DeviceLeaseOwner? = .label("/repo/wt")) -> VMLeaseInfo {
        VMLeaseInfo(
            key: VMPaths.key(number),
            state: state,
            clone: VMPaths.cloneName(slot: number, os: 27),
            ip: state == .ready ? "192.168.64.\(number + 1)" : nil,
            share: "/vms/vm\(number)/share",
            worktree: "/repo/wt",
            guestWorktree: VMPaths.guestWorktree,
            controlSocket: "/vms/vm\(number)/control.sock",
            owner: owner,
            branch: owner == nil ? nil : "feature",
            expiresAt: owner == nil ? nil : Date(timeIntervalSince1970: 1_003_600)
        )
    }

    static func response(_ vm: VMLeaseInfo, created: Bool = true) -> CLIResponse {
        var response = CLIResponse.success
        response.vm = vm
        response.created = created
        return response
    }

    // MARK: Parsing

    @Test func parsesVMCommands() throws {
        #expect(try Devices.parse(["claim", "--kind=vm"]) == .vm(.claim(worktree: nil, owner: nil, ttl: 3600, json: false)))
        #expect(try Devices.parse(["claim", "--kind", "vm", "--worktree=/w", "--owner=ci", "--ttl=60", "--json"])
            == .vm(.claim(worktree: "/w", owner: "ci", ttl: 60, json: true)))
        #expect(try Devices.parse(["release", "vm:1", "--force"]) == .vm(.release(key: "vm:1", owner: nil, force: true)))
        #expect(try Devices.parse(["renew", "vm:2", "--ttl=30"]) == .vm(.renew(key: "vm:2", owner: nil, ttl: 30)))
        #expect(try Devices.parse(["installed", "vm:1", "main"]) == .vm(.installed(key: "vm:1", branch: "main")))
        #expect(try Devices.parse(["reset", "vm:2"]) == .vm(.reset(key: "vm:2")))
        #expect(try Devices.parse(["list", "--kind=vm", "--json"]) == .vm(.list(json: true)))
        #expect(try Devices.parse(["release", "--mine", "--kind=vm"]) == .vm(.releaseMine(owner: nil)))
        #expect(try Devices.parse(["release", "--kind", "vm", "--mine", "--owner=ci"]) == .vm(.releaseMine(owner: "ci")))
    }

    @Test func rejectsBadVMCommands() {
        for arguments in [
            ["claim", "--worktree=/w"], ["claim", "--kind=vm", "R5"], ["claim", "--kind=vm", "--form=tablet"],
            ["claim", "--kind=vm", "--model=x"], ["reset"], ["reset", "R5"], ["reset", "vm:1", "vm:2"],
            ["list", "--kind=emulator"], ["claim", "--kind=vm", "--worktree"],
            ["release", "--kind=vm"], ["release", "vm:1", "--kind=vm"], ["release", "--mine", "--kind=emulator"],
        ] {
            #expect(throws: Devices.UsageError.self, "\(arguments)") { try Devices.parse(arguments) }
        }
    }

    // MARK: main

    struct Run {
        let env = FakeDeviceEnvironment()
        let app = FakeDeviceAppClient()
        let store: DeviceRegistryStore
        init() throws { store = try makeDeviceStore() }

        func callAsFunction(_ arguments: [String], environment: [String: String] = VMDevicesTests.environment) -> (code: Int32, console: BufferConsole) {
            let console = BufferConsole()
            let code = Devices.main(arguments, environment: environment, console: console, devices: env, store: store, app: app)
            return (code, console)
        }

        var requests: [CLIRequest] { app.sent.map(\.request) }
    }

    @Test func claimWaitsForReadyAndPrintsOnlyTheKey() throws {
        let run = try Run()
        var polls = 0
        run.app.reply = { request in
            switch request {
            case .claimVM: return VMDevicesTests.response(VMDevicesTests.slot(1, .reserved))
            case .vmStatus:
                polls += 1
                return VMDevicesTests.response(VMDevicesTests.slot(1, polls < 3 ? .starting : .ready))
            default: return .failure("unexpected")
            }
        }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 0)
        #expect(console.stdout == "vm:1\n")
        #expect(console.stderr.contains("==> claimed vm:1 (192.168.64.2)"))
        #expect(run.app.sent.allSatisfy { $0.socket == VMDevicesTests.socket })
        guard case .claimVM(let claim) = run.requests.first else { Issue.record("no claim sent"); return }
        #expect(claim.owner == .label("/repo/wt"))
        #expect(claim.worktree == "/repo/wt")
        #expect(claim.branch == "feature")
        #expect(polls == 3)
        #expect(try run.store.load().devices.isEmpty)
    }

    @Test func claimJSONNamesEverythingAnAgentNeeds() throws {
        let run = try Run()
        run.app.reply = { request in
            if case .claimVM = request { return VMDevicesTests.response(VMDevicesTests.slot(2, .ready), created: false) }
            return VMDevicesTests.response(VMDevicesTests.slot(2, .ready))
        }
        let (code, console) = run(["claim", "--kind=vm", "--json"])
        #expect(code == 0)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(console.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys).isSuperset(of: [
            "key", "ip", "user", "sshKey", "share", "guestShare", "worktree", "guestWorktree", "controlSocket",
            "owner", "expiresAt", "reused",
        ]))
        #expect(object["key"] as? String == "vm:2")
        #expect(object["reused"] as? Bool == true)
        #expect(object["guestWorktree"] as? String == "/Volumes/My Shared Files/worktree")
    }

    @Test func aFullPoolListsTheLeasesAndExitsThree() throws {
        let run = try Run()
        run.app.reply = { _ in
            var response = CLIResponse.failure("VM pool full (2 of 2 slots in use)")
            response.poolFull = true
            response.vms = [VMDevicesTests.slot(1, .ready, owner: .label("a")), VMDevicesTests.slot(2, .starting, owner: .label("b"))]
            return response
        }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 3)
        #expect(console.stdout.isEmpty)
        let lines = console.stderr.split(separator: "\n").map(String.init)
        #expect(lines.first == "plume devices: VM pool full (2 of 2 slots in use); current VM leases:")
        #expect(lines.count == 4)
        #expect(lines[1].hasPrefix("  vm:1"))
        #expect(lines[1].contains("held by a"))
        #expect(lines[2].hasPrefix("  vm:2"))
    }

    @Test func aFailedBootReleasesTheSlotAndExitsOne() throws {
        let run = try Run()
        run.app.reply = { request in
            switch request {
            case .claimVM: return VMDevicesTests.response(VMDevicesTests.slot(1, .reserved))
            case .vmStatus:
                var failed = VMDevicesTests.slot(1, .failed)
                failed.error = "disk full"
                return VMDevicesTests.response(failed)
            default: return .success
            }
        }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 1)
        #expect(console.stderr.contains("vm:1 failed to boot: disk full"))
        #expect(run.requests.last == .releaseVM(.init(key: "vm:1", owner: .label("/repo/wt"), force: false)))
    }

    @Test func aLeaseTakenOverWhileBootingFailsTheClaimWithoutReleasingIt() throws {
        for takeover in [DeviceLeaseOwner.label("someone else"), .label("/repo/wt")] {
            let run = try Run()
            var claimed = VMDevicesTests.slot(1, .reserved)
            claimed.leaseToken = UUID()
            var next = VMDevicesTests.slot(1, .starting, owner: takeover)
            next.leaseToken = UUID()
            run.app.reply = { request in
                switch request {
                case .claimVM: return VMDevicesTests.response(claimed)
                case .vmStatus: return VMDevicesTests.response(next)
                default: return .success
                }
            }
            let (code, console) = run(["claim", "--kind=vm"])
            #expect(code == 1)
            #expect(console.stderr.contains("lease lost: vm:1"))
            #expect(!run.requests.contains { if case .releaseVM = $0 { true } else { false } })
        }
    }

    @Test func aBootHittingTheVirtualizationLimitExitsThree() throws {
        let run = try Run()
        run.app.reply = { request in
            switch request {
            case .claimVM: return VMDevicesTests.response(VMDevicesTests.slot(1, .reserved))
            case .vmStatus:
                var failed = VMDevicesTests.slot(1, .failed)
                failed.poolFull = true
                return VMDevicesTests.response(failed)
            case .listVMs:
                var response = CLIResponse.success
                response.vms = [VMDevicesTests.slot(1, .idle, owner: nil), VMDevicesTests.slot(2, .idle, owner: nil)]
                return response
            default: return .success
            }
        }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 3)
        #expect(console.stderr.contains("\nplume devices: VM pool full (2 of 2 slots in use); current VM leases:\n"))
    }

    @Test func anAppThatStopsAnsweringFailsTheClaim() throws {
        let run = try Run()
        run.app.reply = { request in
            if case .claimVM = request { return VMDevicesTests.response(VMDevicesTests.slot(1, .reserved)) }
            throw CLIFailure("connection refused")
        }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 1)
        #expect(console.stderr.contains("Plume stopped answering while booting vm:1"))
    }

    @Test func noAppAtAllFailsTheClaim() throws {
        let run = try Run()
        run.app.reply = { _ in throw CLIFailure("no such file") }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 1)
        #expect(console.stderr.contains("VMs need a running Plume"))
    }

    @Test func releaseRenewResetAndInstalledReachTheApp() throws {
        let run = try Run()
        #expect(run(["release", "vm:1"]).code == 0)
        #expect(run(["renew", "vm:1", "--ttl=90"]).code == 0)
        #expect(run(["reset", "vm:2"]).code == 0)
        #expect(run(["installed", "vm:1"]).code == 0)
        let owner = DeviceLeaseOwner.label("/repo/wt")
        #expect(run.requests == [
            .releaseVM(.init(key: "vm:1", owner: owner, force: false)),
            .renewVM(.init(key: "vm:1", owner: owner, ttl: 90)),
            .resetVM(.init(key: "vm:2")),
            .vmInstalled(.init(key: "vm:1", branch: "feature", worktree: "/repo/wt")),
        ])
        #expect(try run.store.load().devices.isEmpty)
    }

    @Test func aRefusalExitsOneWithTheAppsReason() throws {
        let run = try Run()
        run.app.reply = { _ in .failure("vm:1 is leased by another owner, a") }
        let (code, console) = run(["release", "vm:1"])
        #expect(code == 1)
        #expect(console.stderr == "plume devices: vm:1 is leased by another owner, a\n")
    }

    @Test func labsOffPrintsWhereToTurnVMsOn() throws {
        let run = try Run()
        run.app.reply = { _ in .failure("macOS VMs are a Labs feature; turn them on in Settings ▸ Labs") }
        let (code, console) = run(["claim", "--kind=vm"])
        #expect(code == 1)
        #expect(console.stderr == "plume devices: macOS VMs are a Labs feature; turn them on in Settings ▸ Labs\n")
    }

    @Test func listingOnlyVMsNeverRunsADB() throws {
        let run = try Run()
        run.env.adbFailure = "adb not found"
        run.app.reply = { _ in
            var response = CLIResponse.success
            response.vms = [VMDevicesTests.slot(1, .ready), VMDevicesTests.slot(2, .idle, owner: nil)]
            return response
        }
        let (code, console) = run(["list", "--kind=vm"])
        #expect(code == 0)
        let lines = console.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("vm:1"))
        #expect(lines[1].hasSuffix("free"))
    }

    @Test func aPlainListAppendsVMsWhenTheAppAnswers() throws {
        let run = try Run()
        run.env.connect("emulator-5554", avd: "Pixel_8")
        run.app.reply = { _ in
            var response = CLIResponse.success
            response.vms = [VMDevicesTests.slot(1, .idle, owner: nil)]
            return response
        }
        let lines = run(["list"]).console.stdout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("emulator-5554"))
        #expect(lines[1].hasPrefix("vm:1"))

        run.app.reply = { _ in throw CLIFailure("no app") }
        let (code, console) = run(["list"])
        #expect(code == 0)
        #expect(console.stdout.split(separator: "\n").count == 1)
    }

    @Test func releasingAnotherOwnersVMExitsTwo() throws {
        let run = try Run()
        run.app.reply = { _ in
            var response = CLIResponse.failure("vm:1 is leased by another owner, a")
            response.conflict = true
            return response
        }
        let (code, console) = run(["release", "vm:1"])
        #expect(code == Devices.conflictExitCode)
        #expect(console.stderr.contains("leased by another owner"))
    }

    @Test func releaseMineAlsoReleasesMyVMs() throws {
        let run = try Run()
        run.app.reply = { request in
            guard case .listVMs = request else { return .success }
            var response = CLIResponse.success
            response.vms = [
                VMDevicesTests.slot(1, .ready),
                VMDevicesTests.slot(2, .ready, owner: .label("someone else")),
            ]
            return response
        }
        let (code, console) = run(["release", "--mine"])
        #expect(code == 0)
        #expect(console.stdout == "released vm:1\n")
        #expect(run.requests == [.listVMs, .releaseVM(.init(key: "vm:1", owner: .label("/repo/wt"), force: false))])
    }

    @Test func releaseMineTriesEveryVMAndReportsWhatItReleasedBeforeFailing() throws {
        let run = try Run()
        run.app.reply = { request in
            switch request {
            case .listVMs:
                var response = CLIResponse.success
                response.vms = [VMDevicesTests.slot(1, .ready), VMDevicesTests.slot(2, .ready)]
                return response
            case .releaseVM(let params) where params.key == "vm:1":
                return .failure("vm:1 is stopping")
            default:
                return .success
            }
        }
        let (code, console) = run(["release", "--mine"])
        #expect(code == 1)
        #expect(console.stdout == "released vm:2\n")
        #expect(console.stderr.contains("couldn't release vm:1: vm:1 is stopping"))
        #expect(run.requests.count == 3)
    }

    @Test func releaseMineKindVMReleasesOnlyMyVMsAndNeverTouchesTheRegistry() throws {
        let run = try Run()
        run.env.adbFailure = "adb not found"
        run.app.reply = { request in
            guard case .listVMs = request else { return .success }
            var response = CLIResponse.success
            response.vms = [
                VMDevicesTests.slot(1, .ready, owner: .label("someone else")),
                VMDevicesTests.slot(2, .ready),
            ]
            return response
        }
        let (code, console) = run(["release", "--mine", "--kind=vm"])
        #expect(code == 0)
        #expect(console.stdout == "released vm:2\n")
        #expect(run.requests == [.listVMs, .releaseVM(.init(key: "vm:2", owner: .label("/repo/wt"), force: false))])
    }

    @Test func releaseMineKindVMSaysSoWhenNoneIsHeld() throws {
        let run = try Run()
        run.app.reply = { _ in
            var response = CLIResponse.success
            response.vms = [VMDevicesTests.slot(1, .ready, owner: .label("someone else"))]
            return response
        }
        let (code, console) = run(["release", "--mine", "--kind=vm"])
        #expect(code == 0)
        #expect(console.stdout == "no VMs held\n")
        #expect(run.requests == [.listVMs])
    }

    @Test func releaseMineKindVMFailsWhenNoAppAnswers() throws {
        let run = try Run()
        run.app.reply = { _ in throw CLIFailure("no app") }
        let (code, console) = run(["release", "--mine", "--kind=vm"])
        #expect(code == 1)
        #expect(console.stdout.isEmpty)
    }
}
