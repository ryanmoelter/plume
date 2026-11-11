import Foundation

/// `plume devices`: leases on Android devices, so concurrent agents never drive the same one.
/// Unlike the rest of `plume`, a usage error exits 1, keeping device-pool's codes.
nonisolated enum Devices {
    static let programName = "plume devices"
    static let conflictExitCode: Int32 = 2
    static let exhaustedExitCode: Int32 = 3

    static let usage = """
        usage: plume devices <command> [args]

          claim [<serial>] [--kind=emulator|physical|any] [--form=phone|tablet|foldable]
                [--owner=<label>] [--ttl=<sec>] [--json]
                  Claim that device, or a free one, booting an AVD when none is free.
                  Prints only the serial on stdout; progress goes to stderr.
          claim --kind=remote [--model=<codename/api> | --form=phone|tablet|foldable]
                [--owner=<tab id>] [--ttl=<sec>] [--json]
                  Reserve a Device Streaming device in a device tab, and wait until it connects.
                  Only from a Plume tab: the reservation is billed, and ends with the lease.
                  The model defaults to the one last reserved. --owner names the tab that
                  holds a remote device, to claim it again from anywhere.
          release <serial> | --mine [--owner=<label>] [--force]
                  Release a lease. Another owner's lease needs --force. Releasing a remote
                  device ends its reservation.
          renew <serial> [--owner=<label>] [--ttl=<sec>]
                  Extend a lease you hold.
          installed <serial> [<branch>]
                  Record which branch's build is on the device.
          list|ls [--json]
                  Connected devices with their leases.
          prune   Drop stale leases now (every command also does).
          help

        Inside a Plume tab the tab owns the lease; elsewhere the git worktree does, or --owner.
        Leases expire after 1h unless renewed. Target a device with ANDROID_SERIAL.

        exit codes: 0 ok · 1 error or usage · 2 leased by another owner · 3 nothing free
        """

    enum Command: Equatable {
        case claim(serial: String?, kind: DeviceKindFilter, form: DeviceForm?, owner: String?, ttl: TimeInterval, json: Bool)
        case claimRemote(model: String?, form: DeviceForm?, owner: String?, ttl: TimeInterval, json: Bool)
        case release(serial: String?, mine: Bool, owner: String?, force: Bool)
        case renew(serial: String, owner: String?, ttl: TimeInterval)
        case installed(serial: String, branch: String?)
        case list(json: Bool)
        case prune
        case help
    }

    struct UsageError: Error, Equatable {
        var message: String
    }

    static func main(
        _ arguments: [String],
        environment: [String: String],
        console: any CLIConsole,
        devices: (any DeviceEnvironment)? = nil,
        store: DeviceRegistryStore = DeviceRegistryStore(),
        app: any DeviceAppClient = SocketDeviceAppClient()
    ) -> Int32 {
        let command: Command
        do {
            command = try parse(arguments)
        } catch let error as UsageError {
            console.printError("\(programName): \(error.message)")
            console.printError(usage)
            return CLIExitCode.failure
        } catch {
            console.printError("\(programName): \(error.localizedDescription)")
            return CLIExitCode.failure
        }
        if command == .help {
            console.print(usage)
            return CLIExitCode.success
        }

        let devices = devices ?? LiveDeviceEnvironment(environment: environment)
        let pool = DevicePool(
            store: store,
            environment: devices,
            warn: { console.printError("\(programName): \($0)") },
            log: { console.printError("==> \($0)") }
        )
        do {
            try run(command, pool: pool, environment: environment, console: console, app: app)
            return CLIExitCode.success
        } catch DevicePoolError.conflict(let key, let lease) {
            console.printError("\(programName): \(key) is leased by another owner:")
            for line in DevicePool.leaseLines(DeviceRegistry(devices: [key: lease]), now: devices.now()) {
                console.printError(line)
            }
            console.printError("(release it with 'plume devices release \(key) --force' if it's abandoned)")
            return conflictExitCode
        } catch DevicePoolError.booting(let key, let pending) {
            console.printError("\(programName): \(pending.avd ?? key) is booting for another owner, \(pending.owner)")
            return conflictExitCode
        } catch DevicePoolError.exhausted(let lines) {
            console.printError("\(programName): no free device matches; current leases:")
            for line in lines.isEmpty ? ["  (none — no devices connected and no bootable AVDs)"] : lines {
                console.printError(line)
            }
            console.printError("(wait, or 'plume devices release <serial>' one you own)")
            return exhaustedExitCode
        } catch let failure as CLIFailure {
            if let message = failure.message { console.printError("\(programName): \(message)") }
            return failure.code
        } catch {
            console.printError("\(programName): \(error.localizedDescription)")
            return CLIExitCode.failure
        }
    }

    // MARK: Parsing

    static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { return .help }
        var flags = FlagReader(Array(arguments.dropFirst()))
        switch name {
        case "claim":
            var kind = DeviceKindFilter.emulator
            var remote = false
            var model: String?
            var form: DeviceForm?
            var owner: String?
            var ttl = DevicePool.defaultTTL
            var json = false
            var serial: String?
            while let argument = try flags.next() {
                switch argument {
                case .flag("--kind", let value):
                    let raw = try flags.require(value, for: "--kind")
                    remote = raw == DeviceKind.remote.rawValue
                    guard remote || DeviceKindFilter(rawValue: raw) != nil else {
                        throw UsageError(message: "--kind must be one of emulator|physical|any|remote, got: \(raw)")
                    }
                    kind = DeviceKindFilter(rawValue: raw) ?? kind
                case .flag("--model", let value): model = try flags.require(value, for: "--model")
                case .flag("--form", let value):
                    let raw = try flags.require(value, for: "--form")
                    guard let parsed = DeviceForm(rawValue: raw) else {
                        throw UsageError(message: "--form must be one of phone|tablet|foldable, got: \(raw)")
                    }
                    form = parsed
                case .flag("--owner", let value): owner = try ownerLabel(flags.require(value, for: "--owner"))
                case .flag("--ttl", let value): ttl = try parseTTL(flags.require(value, for: "--ttl"))
                case .flag("--json", nil): json = true
                case .positional(let value): try flags.setOnce(&serial, value)
                case .flag(let flag, _): throw UsageError(message: "unknown flag for claim: \(flag)")
                }
            }
            if remote {
                guard serial == nil else {
                    throw UsageError(message: "--kind=remote takes no <serial>; pick the device with --model or --form")
                }
                guard model == nil || form == nil else {
                    throw UsageError(message: "--kind=remote takes --model or --form, not both")
                }
                return .claimRemote(model: model, form: form, owner: owner, ttl: ttl, json: json)
            }
            guard model == nil else { throw UsageError(message: "--model needs --kind=remote") }
            return .claim(serial: serial, kind: kind, form: form, owner: owner, ttl: ttl, json: json)
        case "release":
            var serial: String?
            var mine = false
            var owner: String?
            var force = false
            while let argument = try flags.next() {
                switch argument {
                case .flag("--mine", nil): mine = true
                case .flag("--force", nil): force = true
                case .flag("--owner", let value): owner = try ownerLabel(flags.require(value, for: "--owner"))
                case .positional(let value): try flags.setOnce(&serial, value)
                case .flag(let flag, _): throw UsageError(message: "unknown flag for release: \(flag)")
                }
            }
            guard (serial != nil) != mine else { throw UsageError(message: "release takes a <serial> or --mine") }
            return .release(serial: serial, mine: mine, owner: owner, force: force)
        case "renew":
            var serial: String?
            var owner: String?
            var ttl = DevicePool.defaultTTL
            while let argument = try flags.next() {
                switch argument {
                case .flag("--owner", let value): owner = try ownerLabel(flags.require(value, for: "--owner"))
                case .flag("--ttl", let value): ttl = try parseTTL(flags.require(value, for: "--ttl"))
                case .positional(let value): try flags.setOnce(&serial, value)
                case .flag(let flag, _): throw UsageError(message: "unknown flag for renew: \(flag)")
                }
            }
            guard let serial else { throw UsageError(message: "renew takes a <serial>") }
            return .renew(serial: serial, owner: owner, ttl: ttl)
        case "installed":
            var positionals: [String] = []
            while let argument = try flags.next() {
                switch argument {
                case .positional(let value): positionals.append(value)
                case .flag(let flag, _): throw UsageError(message: "unknown flag for installed: \(flag)")
                }
            }
            guard (1...2).contains(positionals.count) else {
                throw UsageError(message: "installed takes a <serial> and optionally a <branch>")
            }
            return .installed(serial: positionals[0], branch: positionals.count > 1 ? positionals[1] : nil)
        case "list", "ls":
            var json = false
            while let argument = try flags.next() {
                switch argument {
                case .flag("--json", nil): json = true
                case .positional(let value), .flag(let value, _): throw UsageError(message: "unknown argument for list: \(value)")
                }
            }
            return .list(json: json)
        case "prune":
            if let argument = arguments.dropFirst().first { throw UsageError(message: "unexpected argument: \(argument)") }
            return .prune
        case "help", "-h", "--help":
            return .help
        default:
            throw UsageError(message: "unknown command: \(name)")
        }
    }

    /// Reads `--flag=value`, `--flag value` for the flags that take one, bare flags and
    /// positionals. `--` ends the flags.
    struct FlagReader {
        enum Argument: Equatable {
            case flag(String, String?)
            case positional(String)
        }

        static let valued: Set<String> = ["--kind", "--form", "--owner", "--ttl", "--model"]

        private var rest: ArraySlice<String>
        private var onlyPositionals = false

        init(_ arguments: [String]) {
            rest = arguments[...]
        }

        mutating func next() throws -> Argument? {
            guard let argument = rest.popFirst() else { return nil }
            if onlyPositionals || !argument.hasPrefix("-") || argument == "-" { return .positional(argument) }
            if argument == "--" {
                onlyPositionals = true
                return try next()
            }
            if let equals = argument.firstIndex(of: "=") {
                return .flag(String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
            }
            if Self.valued.contains(argument), let value = rest.popFirst() {
                return .flag(argument, value)
            }
            return .flag(argument, nil)
        }

        func require(_ value: String?, for flag: String) throws -> String {
            guard let value else { throw UsageError(message: "\(flag) needs a value") }
            return value
        }

        func setOnce(_ slot: inout String?, _ value: String) throws {
            guard slot == nil else { throw UsageError(message: "unexpected argument: \(value)") }
            slot = value
        }
    }

    static func parseTTL(_ value: String) throws -> TimeInterval {
        guard let seconds = Int(value), seconds > 0 else {
            throw UsageError(message: "--ttl must be a positive integer of seconds, got: \(value)")
        }
        return TimeInterval(seconds)
    }

    static func ownerLabel(_ value: String) throws -> String {
        guard !value.isEmpty else { throw UsageError(message: "--owner needs a value") }
        return value
    }

    // MARK: Owners

    /// `--owner` wins. Inside a Plume tab the tab owns the lease, together with the socket of the
    /// app that owns the tab. Elsewhere the enclosing git worktree does.
    static func claimant(ownerFlag: String?, environment: [String: String], devices: any DeviceEnvironment) throws -> DeviceClaimant {
        let info = devices.ownerInfo()
        if let ownerFlag {
            return DeviceClaimant(owner: .label(ownerFlag), worktree: info?.worktree, branch: info?.branch)
        }
        if let tabID = environment[CLISocket.tabIDEnvironmentKey].flatMap(UUID.init(uuidString:)),
           let socket = environment[CLISocket.pathEnvironmentKey], !socket.isEmpty {
            return DeviceClaimant(owner: .tab(id: tabID, app: socket), worktree: info?.worktree, branch: info?.branch)
        }
        guard let info else {
            throw CLIFailure("not inside a Plume tab or a git repository; pass --owner=<label>")
        }
        return DeviceClaimant(owner: .label(info.worktree), worktree: info.worktree, branch: info.branch)
    }

    // MARK: Commands

    static func run(
        _ command: Command,
        pool: DevicePool,
        environment: [String: String],
        console: any CLIConsole,
        app: any DeviceAppClient
    ) throws {
        let devices = pool.environment
        switch command {
        case .claim(let serial, let kind, let form, let owner, let ttl, let json):
            let claimant = try claimant(ownerFlag: owner, environment: environment, devices: devices)
            let claimed: (key: String, serial: String, lease: DeviceLease, reused: Bool)
            if let serial {
                let key = try pool.leaseKey(for: serial)
                if let held = try? pool.lease(key, owner: claimant.owner, force: false), held.kind == .remote {
                    try extendRemote(key: key, lease: held, ttl: ttl, app: app)
                }
                let result = try pool.claimSerial(serial, claimant: claimant, ttl: ttl)
                claimed = (result.key, serial, result.lease, result.reused)
            } else {
                let result = try pool.acquire(claimant: claimant, ttl: ttl, kind: kind, form: form)
                claimed = (result.serial, result.serial, result.lease, result.reused)
            }
            if case .tab(let tabID, let socket) = claimant.owner {
                showDeviceTab(key: claimed.key, lease: claimed.lease, callerTab: tabID, socket: socket, pool: pool, app: app, console: console)
            }
            try printClaim(serial: claimed.serial, lease: claimed.lease, reused: claimed.reused, json: json, console: console)
        case .claimRemote(let model, let form, let owner, let ttl, let json):
            let claimed = try claimRemote(
                model: model, form: form, ownerFlag: owner, ttl: ttl, pool: pool, environment: environment, app: app
            )
            try printClaim(serial: claimed.lease.serial ?? claimed.key, lease: claimed.lease, reused: claimed.reused, json: json, console: console)
        case .release(let serial, let mine, let owner, let force):
            let claimant = try claimant(ownerFlag: owner, environment: environment, devices: devices)
            if mine {
                let released = try pool.releaseMine(owner: claimant.owner).map(\.key)
                let remote = try pool.remoteLeases(ownedBy: claimant.owner)
                for (key, lease) in remote { try releaseRemote(key: key, lease: lease, pool: pool, app: app, console: console) }
                let all = released + remote.map(\.key)
                console.print(all.isEmpty ? "no leases held" : "released " + all.joined(separator: ", "))
            } else if let serial {
                let key = try pool.leaseKey(for: serial)
                if let held = try pool.lease(key, owner: claimant.owner, force: force), held.kind == .remote {
                    try releaseRemote(key: key, lease: held, pool: pool, app: app, console: console)
                    console.print("released \(serial)")
                } else if try pool.release(key, owner: claimant.owner, force: force) != nil {
                    console.print("released \(serial)")
                } else {
                    console.print("\(serial) was not leased")
                }
            }
        case .renew(let serial, let owner, let ttl):
            let claimant = try claimant(ownerFlag: owner, environment: environment, devices: devices)
            let key = try pool.leaseKey(for: serial)
            if let held = try pool.lease(key, owner: claimant.owner, force: false), held.kind == .remote {
                try extendRemote(key: key, lease: held, ttl: ttl, app: app)
            }
            _ = try pool.renew(key, owner: claimant.owner, ttl: ttl)
            console.print("renewed \(serial) for \(Int(ttl))s")
        case .installed(let serial, let branch):
            let info = devices.ownerInfo()
            guard let branch = branch ?? info?.branch else {
                throw CLIFailure("no <branch> given and none detectable from the current repo")
            }
            if try pool.noteInstalled(pool.leaseKey(for: serial), branch: branch, worktree: info?.worktree) {
                console.print("recorded \(branch) on \(serial)")
            } else {
                console.printError("\(programName): \(serial) has no lease to annotate (claim it first)")
            }
        case .list(let json):
            let rows = try pool.listing()
            if json {
                try console.print(jsonLine(ListResult(devices: rows), pretty: true))
            } else if rows.isEmpty {
                console.print("no devices connected")
            } else {
                let color = console.stdoutIsTerminal && environment["NO_COLOR"] == nil
                for row in rows { console.print(listLine(row, now: devices.now(), color: color)) }
            }
        case .prune:
            let messages = try pool.prune()
            console.print(messages.isEmpty ? "nothing to reap" : messages.joined(separator: "\n"))
        case .help:
            console.print(usage)
        }
    }

    static func printClaim(serial: String, lease: DeviceLease, reused: Bool, json: Bool, console: any CLIConsole) throws {
        if json {
            try console.print(jsonLine(ClaimResult(
                serial: serial,
                kind: lease.kind,
                avd: lease.avd,
                form: lease.form,
                model: lease.kind == .remote ? lease.model : nil,
                owner: lease.owner,
                expiresAt: lease.expiresAt,
                reused: reused
            )))
        } else {
            let verb = reused ? "renewed lease on" : "claimed"
            console.printError("==> \(verb) \(serial)" + ((lease.avd ?? (lease.kind == .remote ? lease.model : nil)).map { " (\($0))" } ?? ""))
            console.print(serial)
        }
    }

    static let remoteNeedsATab = "a remote device is billed and must belong to a Plume tab"

    /// The tab ID an `--owner` names: a bare UUID, or the `Plume tab <uuid>` that lease listings print.
    static func ownerTabID(_ ownerFlag: String) -> UUID? {
        let prefix = "Plume tab "
        let id = ownerFlag.hasPrefix(prefix) ? String(ownerFlag.dropFirst(prefix.count)) : ownerFlag
        return UUID(uuidString: id.trimmingCharacters(in: .whitespaces))
    }

    /// Who a remote claim is for. Only a tab can hold a remote device, so `--owner` must name one:
    /// the calling tab, which may reserve, or a tab elsewhere that already holds a device, which is
    /// claimed again but never reserved for.
    static func remoteClaimant(
        ownerFlag: String?,
        environment: [String: String],
        pool: DevicePool
    ) throws -> (claimant: DeviceClaimant, mayReserve: Bool) {
        let devices = pool.environment
        guard let ownerFlag else {
            let claimant = try claimant(ownerFlag: nil, environment: environment, devices: devices)
            guard case .tab = claimant.owner else { throw CLIFailure(remoteNeedsATab) }
            return (claimant, true)
        }
        guard let tabID = ownerTabID(ownerFlag) else {
            throw CLIFailure("\(remoteNeedsATab), so --owner must name one by its tab ID, not \(ownerFlag)")
        }
        let info = devices.ownerInfo()
        if environment[CLISocket.tabIDEnvironmentKey].flatMap(UUID.init(uuidString:)) == tabID,
           let socket = environment[CLISocket.pathEnvironmentKey], !socket.isEmpty {
            return (DeviceClaimant(owner: .tab(id: tabID, app: socket), worktree: info?.worktree, branch: info?.branch), true)
        }
        guard let owner = try pool.remoteOwner(ofTab: tabID) else {
            throw CLIFailure(holdsNoRemoteDevice(tabID))
        }
        return (DeviceClaimant(owner: owner, worktree: info?.worktree, branch: info?.branch), false)
    }

    static func holdsNoRemoteDevice(_ tabID: UUID) -> String {
        "Plume tab \(tabID.uuidString) holds no remote device; only that tab can reserve one"
    }

    /// Asks the tab's app to reserve a device, then waits for the lease it writes once the device
    /// connects. A device this tab already holds is renewed, and a reservation still starting is
    /// waited on again rather than doubled.
    static func claimRemote(
        model: String?,
        form: DeviceForm?,
        ownerFlag: String?,
        ttl: TimeInterval,
        pool: DevicePool,
        environment: [String: String],
        app: any DeviceAppClient
    ) throws -> (key: String, lease: DeviceLease, reused: Bool) {
        let devices = pool.environment
        let (claimant, mayReserve) = try remoteClaimant(ownerFlag: ownerFlag, environment: environment, pool: pool)
        guard case .tab(let tabID, let socket) = claimant.owner else { throw CLIFailure(remoteNeedsATab) }
        do {
            _ = try app.send(.ping, to: socket)
        } catch {
            throw CLIFailure("\(remoteNeedsATab), and the Plume that owns this tab isn't answering: \(describe(error))")
        }
        let waiter = RemoteClaimWaiter(store: pool.store, app: app, socket: socket, now: devices.now, sleep: devices.sleep, log: pool.log)
        if let (key, lease) = try pool.heldRemoteLease(owner: claimant.owner) {
            let held = "\(lease.serial ?? key) (\(lease.model ?? "another model"))"
            if let model, lease.model != model {
                throw CLIFailure("this tab already holds \(held); release it before reserving \(model)")
            }
            // A lease with no form named a model the catalog didn't classify, so it can't conflict.
            if let form, let heldForm = lease.form, heldForm != form {
                throw CLIFailure("this tab already holds \(held), a \(heldForm.rawValue); release it before reserving a \(form.rawValue)")
            }
            try extendRemote(key: key, lease: lease, ttl: ttl, app: app)
            return (key, try pool.renew(key, owner: claimant.owner, ttl: ttl), true)
        }
        guard mayReserve else { throw CLIFailure(holdsNoRemoteDevice(tabID)) }
        // A claim still reserving for this tab is joined by the app, which writes its pending
        // entry again, so a wait that outlasts the entry's expiry never fails falsely.
        let response = try app.send(.reserveDevice(.init(
            tabID: tabID, model: model, form: form, ttl: ttl, worktree: claimant.worktree, branch: claimant.branch
        )), to: socket)
        guard response.ok, let claimID = response.claimID else {
            throw CLIFailure("couldn't reserve a remote device: \(response.error ?? "Plume started no reservation")")
        }
        let wanted = model ?? form.map { "a \($0.rawValue)" } ?? "the model last reserved"
        pool.log("reserving \(wanted) in a device tab; Device Streaming can take a few minutes")
        let leased = try waiter.wait(for: claimID)
        return (leased.key, leased.lease, false)
    }

    /// A remote lease is only as long as the reservation behind it, so the app holding that
    /// reservation extends it before the lease is renewed.
    static func extendRemote(key: String, lease: DeviceLease, ttl: TimeInterval, app: any DeviceAppClient) throws {
        guard let socket = lease.owner.app else {
            throw CLIFailure("\(key) belongs to no Plume, so its reservation can't be extended")
        }
        let response: CLIResponse
        do {
            response = try app.send(.extendDevice(.init(key: key, ttl: ttl)), to: socket)
        } catch {
            throw CLIFailure("couldn't reach the Plume holding \(key) to extend its reservation: \(describe(error))")
        }
        guard response.ok else {
            throw CLIFailure("couldn't extend the reservation behind \(key): \(response.error ?? "no reason given")")
        }
    }

    /// The owning app ends the reservation with the lease. An app that can't be reached leaves the
    /// lease to be dropped here; its reservation ends when that app quits or next launches.
    static func releaseRemote(key: String, lease: DeviceLease, pool: DevicePool, app: any DeviceAppClient, console: any CLIConsole) throws {
        if let socket = lease.owner.app {
            do {
                let response = try app.send(.releaseDevice(.init(key: key)), to: socket)
                if response.ok { return }
                console.printError("\(programName): Plume didn't release \(key): \(response.error ?? "no reason given"); dropping the lease")
            } catch {
                console.printError(
                    "\(programName): couldn't reach the Plume holding \(key) (\(describe(error))); dropping the lease, "
                        + "and its reservation ends when that Plume quits or next launches"
                )
            }
        }
        _ = try pool.release(key, owner: lease.owner, force: true)
    }

    static func describe(_ error: any Error) -> String {
        (error as? CLIFailure)?.message ?? error.localizedDescription
    }

    /// Best effort: the lease stands whether or not a tab opens.
    static func showDeviceTab(
        key: String,
        lease: DeviceLease,
        callerTab: UUID,
        socket: String,
        pool: DevicePool,
        app: any DeviceAppClient,
        console: any CLIConsole
    ) {
        let request = CLIRequest.showDevice(.init(
            tabID: callerTab,
            kind: lease.kind,
            serial: lease.serial,
            avdID: lease.avd,
            reservationID: lease.remote?.reservationID,
            displayName: lease.kind == .physical ? lease.model?.replacingOccurrences(of: "_", with: " ") : nil
        ))
        do {
            let response = try app.send(request, to: socket)
            guard response.ok, let deviceTab = response.tabID else {
                console.printError("\(programName): couldn't open a device tab: \(response.error ?? "Plume named no tab")")
                return
            }
            try pool.recordDeviceTab(key, owner: lease.owner, tabID: deviceTab, created: response.created == true)
        } catch {
            console.printError("\(programName): couldn't open a device tab: \(describe(error))")
        }
    }

    private struct ClaimResult: Encodable {
        var serial: String
        var kind: DeviceKind
        var avd: String?
        var form: DeviceForm?
        var model: String?
        var owner: DeviceLeaseOwner
        var expiresAt: Date
        var reused: Bool
    }

    private struct ListResult: Encodable {
        var devices: [DeviceListingRow]
    }

    static func jsonLine(_ value: some Encodable, pretty: Bool = false) throws -> String {
        let encoder = DeviceRegistryCodec.makeEncoder()
        if !pretty { encoder.outputFormatting.remove(.prettyPrinted) }
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func listLine(_ row: DeviceListingRow, now: Date, color: Bool) -> String {
        func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
        let serial = row.serial ?? "(\(row.state))"
        var what = row.avd ?? row.lease?.model ?? row.pending?.model ?? row.kind.rawValue
        if let form = row.form { what += " [\(form.rawValue)]" }
        let state: String
        if let pending = row.pending {
            state = paint("\(row.state) for \(pending.owner)", "33")
        } else if let lease = row.lease {
            var held = paint("held by \(DevicePool.holder(lease)), expires in \(DevicePool.relativeTime(lease.expiresAt.timeIntervalSince(now)))", "33")
            if let installed = lease.installed { held += paint(" · installed: \(installed.branch)", "2") }
            state = held
        } else if row.kind == .remote {
            state = paint("remote, not leased", "2")
        } else if row.state == "device" {
            state = paint("free", "32")
        } else {
            state = row.state
        }
        return pad(serial, 22) + " " + pad(what, 28) + " " + state
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
