import Foundation

/// `plume devices` for macOS VMs. The app owns the VMs, so every command asks the app over its
/// socket and nothing touches the registry or adb. `docs/vm-testing.md` is the reference.
nonisolated extension Devices {
    enum VMCommand: Equatable {
        case claim(worktree: String?, owner: String?, ttl: TimeInterval, json: Bool)
        case release(key: String, owner: String?, force: Bool)
        case releaseMine(owner: String?)
        case renew(key: String, owner: String?, ttl: TimeInterval)
        case installed(key: String, branch: String?)
        case reset(key: String)
        case list(json: Bool)
    }

    /// Every slot is in use; `slots` are the app's VM rows for the message.
    struct VMPoolFull: Error {
        var slots: [VMLeaseInfo]
    }

    /// The app has 4 minutes to boot a VM; this outlasts that so its own failure is what's reported.
    static let vmReadyTimeout: TimeInterval = 300
    static let vmPollInterval: TimeInterval = 2
    static let vmProgressInterval: TimeInterval = 30

    static func vmSocket(environment: [String: String]) throws -> String {
        guard let socket = CLISocket.resolvedPath(environment: environment) else {
            throw CLIFailure("this tab's Plume serves no socket, and only a running Plume can run a VM")
        }
        return socket
    }

    static func sendVM(_ request: CLIRequest, socket: String, app: any DeviceAppClient) throws -> CLIResponse {
        let response: CLIResponse
        do {
            response = try app.send(request, to: socket)
        } catch {
            throw CLIFailure("VMs need a running Plume, and none answered at \(socket): \(describe(error))")
        }
        if response.poolFull == true { throw VMPoolFull(slots: response.vms ?? []) }
        guard response.ok else {
            throw CLIFailure(response.error ?? "Plume refused without saying why", code: response.conflict == true ? conflictExitCode : CLIExitCode.failure)
        }
        return response
    }

    static func runVM(
        _ command: VMCommand,
        environment: [String: String],
        console: any CLIConsole,
        devices: any DeviceEnvironment,
        app: any DeviceAppClient
    ) throws {
        let socket = try vmSocket(environment: environment)
        let log: (String) -> Void = { console.printError("==> \($0)") }
        switch command {
        case .claim(let worktreeFlag, let ownerFlag, let ttl, let json):
            let claimant = try claimant(ownerFlag: ownerFlag, environment: environment, devices: devices)
            let worktree = worktreeFlag.map { CLIPath.resolved(CLIPath.absolute($0)) } ?? claimant.worktree
            let response = try sendVM(
                .claimVM(.init(owner: claimant.owner, worktree: worktree, branch: claimant.branch, ttl: ttl)), socket: socket, app: app
            )
            guard let claimed = response.vm else { throw CLIFailure("Plume named no VM slot") }
            let reused = response.created == false
            if claimed.state != .ready { log("\(reused ? "renewed" : "claimed") \(claimed.key); booting \(claimed.clone)") }
            let ready = try waitForVM(
                claimed.key, owner: claimant.owner, token: claimed.leaseToken, socket: socket, app: app, devices: devices, log: log
            )
            if json {
                try console.print(jsonLine(VMClaimResult(ready, reused: reused)))
            } else {
                console.printError("==> \(reused ? "renewed lease on" : "claimed") \(ready.key) (\(ready.ip ?? "no address"))")
                console.print(ready.key)
            }
        case .release(let key, let ownerFlag, let force):
            let owner = try claimant(ownerFlag: ownerFlag, environment: environment, devices: devices).owner
            _ = try sendVM(.releaseVM(.init(key: key, owner: owner, force: force)), socket: socket, app: app)
            console.print("released \(key)")
        case .releaseMine(let ownerFlag):
            let owner = try claimant(ownerFlag: ownerFlag, environment: environment, devices: devices).owner
            let slots = try sendVM(.listVMs, socket: socket, app: app).vms ?? []
            let vms = releaseVMs(slots.filter { $0.owner == owner }, owner: owner, socket: socket, app: app)
            if !vms.released.isEmpty || vms.failures.isEmpty {
                console.print(vms.released.isEmpty ? "no VMs held" : "released " + vms.released.joined(separator: ", "))
            }
            if !vms.failures.isEmpty { throw CLIFailure("couldn't release " + vms.failures.joined(separator: "; ")) }
        case .renew(let key, let ownerFlag, let ttl):
            let owner = try claimant(ownerFlag: ownerFlag, environment: environment, devices: devices).owner
            _ = try sendVM(.renewVM(.init(key: key, owner: owner, ttl: ttl)), socket: socket, app: app)
            console.print("renewed \(key) for \(Int(ttl))s")
        case .installed(let key, let branchArgument):
            let info = devices.ownerInfo()
            guard let branch = branchArgument ?? info?.branch else {
                throw CLIFailure("no <branch> given and none detectable from the current repo")
            }
            _ = try sendVM(.vmInstalled(.init(key: key, branch: branch, worktree: info?.worktree)), socket: socket, app: app)
            console.print("recorded \(branch) on \(key)")
        case .reset(let key):
            _ = try sendVM(.resetVM(.init(key: key)), socket: socket, app: app)
            console.print("reset \(key); its next claim clones the base image again")
        case .list(let json):
            let slots = try sendVM(.listVMs, socket: socket, app: app).vms ?? []
            if json {
                try console.print(jsonLine(VMListResult(vms: slots), pretty: true))
            } else {
                let color = console.stdoutIsTerminal && environment["NO_COLOR"] == nil
                for slot in slots { console.print(vmListLine(slot, now: devices.now(), color: color)) }
            }
        }
    }

    /// Polls the app until the VM is ready. A failed boot releases the slot, so it isn't left
    /// leased to a claimant that has given up. The poll fails once the slot holds a lease other
    /// than the one claimed: `token` is that lease's, or nil from an app that mints none.
    static func waitForVM(
        _ key: String,
        owner: DeviceLeaseOwner,
        token: UUID?,
        socket: String,
        app: any DeviceAppClient,
        devices: any DeviceEnvironment,
        log: (String) -> Void
    ) throws -> VMLeaseInfo {
        let started = devices.now()
        var lastProgress = started
        var lastState: VMSlotState?
        while true {
            let response: CLIResponse
            do {
                response = try app.send(.vmStatus(.init(key: key)), to: socket)
            } catch {
                throw CLIFailure("Plume stopped answering while booting \(key): \(describe(error))")
            }
            guard response.ok, let slot = response.vm else {
                throw CLIFailure("Plume lost \(key) while booting it: \(response.error ?? "no reason given")")
            }
            if let holder = slot.owner, holder != owner || (token != nil && slot.leaseToken != token) {
                throw CLIFailure("lease lost: \(key) was released and claimed again by \(holder) before it was ready")
            }
            switch slot.state {
            case .ready:
                return slot
            case .failed:
                _ = try? app.send(.releaseVM(.init(key: key, owner: owner, force: false)), to: socket)
                if slot.poolFull == true {
                    let slots = (try? app.send(.listVMs, to: socket))?.vms ?? []
                    throw VMPoolFull(slots: slots)
                }
                throw CLIFailure("\(key) failed to boot: \(slot.error ?? "no reason given")")
            case .idle, .stopping, .resetting:
                throw CLIFailure("\(key) was released before it was ready")
            case .reserved, .cloning, .starting:
                break
            }
            let elapsed = devices.now().timeIntervalSince(started)
            if elapsed >= vmReadyTimeout {
                throw CLIFailure("\(key) still isn't ready after \(Int(vmReadyTimeout / 60)) minutes; it stays leased, and claiming again waits for it")
            }
            if slot.state != lastState || devices.now().timeIntervalSince(lastProgress) >= vmProgressInterval {
                if lastState != nil { log("\(key) \(slot.state.rawValue) (\(DevicePool.relativeTime(elapsed)))") }
                lastState = slot.state
                lastProgress = devices.now()
            }
            devices.sleep(vmPollInterval)
        }
    }

    static func printVMPoolFull(_ full: VMPoolFull, console: any CLIConsole, now: Date) {
        console.printError("\(programName): VM pool full (\(VMPaths.slotCount) of \(VMPaths.slotCount) slots in use); current VM leases:")
        for slot in full.slots { console.printError("  " + vmListLine(slot, now: now, color: false)) }
        console.printError("(wait, or 'plume devices release vm:<n>' one you own)")
    }

    /// Releases every VM `owner` holds, trying each even after one fails. None when no app
    /// answers, so `release --mine` still releases the devices.
    static func releaseVMs(
        ownedBy owner: DeviceLeaseOwner, environment: [String: String], app: any DeviceAppClient
    ) -> (released: [String], failures: [String]) {
        guard let socket = CLISocket.resolvedPath(environment: environment) else { return ([], []) }
        let held = vmRowsIfAnswering(environment: environment, app: app).filter { $0.owner == owner }
        return releaseVMs(held, owner: owner, socket: socket, app: app)
    }

    static func releaseVMs(
        _ slots: [VMLeaseInfo], owner: DeviceLeaseOwner, socket: String, app: any DeviceAppClient
    ) -> (released: [String], failures: [String]) {
        var released: [String] = []
        var failures: [String] = []
        for slot in slots {
            do {
                _ = try sendVM(.releaseVM(.init(key: slot.key, owner: owner, force: false)), socket: socket, app: app)
                released.append(slot.key)
            } catch {
                failures.append("\(slot.key): \(describe(error))")
            }
        }
        return (released, failures)
    }

    /// The app's VM rows, or none when no app answers: a plain `list` still shows the devices.
    static func vmRowsIfAnswering(environment: [String: String], app: any DeviceAppClient) -> [VMLeaseInfo] {
        guard let socket = CLISocket.resolvedPath(environment: environment),
              let response = try? app.send(.listVMs, to: socket), response.ok
        else { return [] }
        return response.vms ?? []
    }

    static func vmListLine(_ slot: VMLeaseInfo, now: Date, color: Bool) -> String {
        func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        let what = slot.clone + (slot.ip.map { " (\($0))" } ?? "")
        var state: String
        if let owner = slot.owner {
            let holder = slot.branch.map { "\(owner) (branch \($0))" } ?? owner.description
            let expiry = slot.expiresAt.map { ", expires in \(DevicePool.relativeTime($0.timeIntervalSince(now)))" } ?? ""
            state = paint("\(slot.state.rawValue), held by \(holder)\(expiry)", "33")
            if let installed = slot.installed { state += paint(" · installed: \(installed.branch)", "2") }
        } else if slot.heldElsewhere == true {
            state = paint("in use by another Plume", "33")
        } else if slot.state == .idle {
            state = paint("free", "32")
        } else {
            state = slot.state.rawValue
        }
        if let error = slot.error { state += " · " + paint(error, "31") }
        return pad(slot.key, 22) + " " + pad(what, 28) + " " + state
    }

    struct VMClaimResult: Encodable {
        var slot: VMLeaseInfo
        var reused: Bool

        init(_ slot: VMLeaseInfo, reused: Bool) {
            self.slot = slot
            self.reused = reused
        }

        private enum CodingKeys: String, CodingKey { case reused }

        func encode(to encoder: any Encoder) throws {
            try slot.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reused, forKey: .reused)
        }
    }

    struct VMListResult: Encodable {
        var vms: [VMLeaseInfo]
    }
}
