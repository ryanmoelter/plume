import AppKit
import Foundation
import GhosttyTerminal
import SwiftData

/// Answers the requests `CLIServer` receives.
@MainActor
final class CLICommandHandler {
    static let shared = CLICommandHandler()

    /// What an open main window offers a request. `MainWindow` registers one
    /// per window, keeping SwiftData queries out of here.
    struct WindowRegistration {
        /// Nil until the view finds its window.
        var window: () -> NSWindow?
        var task: (UUID) -> WorkTask?
        var taskIDForTab: (UUID) -> UUID?
        var context: ModelContext
        /// Shows the task in this window, for `tab new --select`.
        var reveal: (UUID) -> Void
        var openSettings: () -> Void = {}
    }

    /// A checkout `task.new` opens: which project it belongs to, and its
    /// branch, nil when detached.
    nonisolated struct Checkout: Sendable {
        var facts: CheckoutFacts
        var branch: String?
    }

    /// Most recently registered last.
    private var registrations: [(id: UUID, registration: WindowRegistration)] = []

    var orderedWindows: () -> [NSWindow] = { NSApp.orderedWindows }
    var directories: TabDirectoryStore = .shared
    var deviceSessions: DeviceSessionManager = .shared
    var deviceLeases: DeviceLeaseCoordinator = .shared
    var physicalDiscovery: PhysicalDeviceDiscovery = .shared
    var remoteDevices = RemoteDeviceDefaults()
    var clock: () -> Date = Date.init

    /// What `devices.reserve` falls back on, and how it starts a reservation, so tests reserve
    /// nothing.
    struct RemoteDeviceDefaults {
        var project: @MainActor () async -> String? = {
            await RemoteDeviceCatalog.shared.loadIfNeeded()
            return RemoteDeviceCatalog.shared.selectedProject
        }
        var recentModel: @MainActor () -> String? = { AppSettings.shared.recentRemoteDeviceModels.first }
        var models: @MainActor () async -> [RemoteDeviceModel] = {
            await RemoteDeviceCatalog.shared.loadModels()
            return RemoteDeviceCatalog.shared.models
        }
        var reserve: @MainActor (_ tab: TaskTab, _ modelID: String, _ displayName: String, _ projectID: String) -> Void = {
            DeviceSessionManager.shared.prepareSession(for: $0).reserve(modelID: $1, displayName: $2, projectID: $3)
        }
    }

    func registerWindow(_ id: UUID, _ registration: WindowRegistration) {
        unregisterWindow(id)
        registrations.append((id, registration))
    }

    func unregisterWindow(_ id: UUID) {
        registrations.removeAll { $0.id == id }
    }

    /// By screen order, then by most recent registration for a window not on
    /// screen yet.
    private var frontmostFirst: [WindowRegistration] {
        let screenOrder = orderedWindows()
        let byRecency = registrations.reversed().map(\.registration)
        return byRecency.enumerated().sorted { lhs, rhs in
            let left = lhs.element.window().flatMap { window in screenOrder.firstIndex { $0 === window } } ?? .max
            let right = rhs.element.window().flatMap { window in screenOrder.firstIndex { $0 === window } } ?? .max
            return (left, lhs.offset) < (right, rhs.offset)
        }.map(\.element)
    }

    var frontmostWindow: WindowRegistration? { frontmostFirst.first }

    var notify: (_ tabID: UUID, _ title: String, _ body: String) -> Bool = { tabID, title, body in
        TerminalAlerts.shared.notify(tabID: tabID, title: title, body: body)
    }

    var inspectCheckout: @Sendable (String) async -> Checkout? = { path in
        guard let facts = await GitService.shared.checkoutFacts(containing: path) else { return nil }
        let branch = await GitService.shared.currentBranch(in: path)
        return Checkout(facts: facts, branch: branch == "HEAD" ? nil : branch)
    }

    /// Where `SettingsView` keeps its selected pane.
    var settingsDefaults: UserDefaults = .standard
    var activateApp: () -> Void = { NSApp.activate() }

    func handle(_ request: CLIRequest) async -> CLIResponse {
        switch request {
        case .ping:
            var response = CLIResponse.success
            response.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            return response
        case .notify(let params):
            guard notify(params.tabID, params.title, params.body) else {
                return .failure("no Plume tab \(params.tabID.uuidString)")
            }
            return .success
        case .newTab(let params):
            return newTab(params)
        case .newTask(let params):
            return await newTask(params)
        case .openSettings(let params):
            return openSettings(params)
        case .showDevice(let params):
            return await showDevice(params)
        case .reserveDevice(let params):
            return await reserveDevice(params)
        case .releaseDevice(let params):
            return await releaseDevice(params)
        case .extendDevice(let params):
            return await extendDevice(params)
        }
    }

    /// The task the tab is in now, which a moved tab changes.
    private func currentTask(ofTab tabID: UUID) -> (task: WorkTask, context: ModelContext)? {
        let windows = frontmostFirst
        guard let taskID = windows.lazy.compactMap({ $0.taskIDForTab(tabID) }).first else { return nil }
        return windows.lazy.compactMap { window in window.task(taskID).map { (task: $0, context: window.context) } }.first
    }

    /// Prefers a device tab already on the device, then one with no device, then a new tab
    /// opposite the caller's pane, behind the selection. A tab on another device is never repointed.
    private func showDevice(_ params: CLIRequest.ShowDevice) async -> CLIResponse {
        guard let target = await deviceTarget(params) else {
            return .failure("devices.show needs an avdID for an emulator, a serial for a physical device, or a reservationID for a remote one")
        }
        guard let (task, context) = currentTask(ofTab: params.tabID) else {
            return .failure("no Plume tab \(params.tabID.uuidString)")
        }
        let deviceTabs = task.orderedTabs.filter { $0.kind == .device }
        let tab: TaskTab
        var created = false
        if let showing = deviceTabs.first(where: { $0.deviceTarget.map { isSameDevice($0, target) } ?? false }) {
            tab = showing
        } else if case .remote(let reservationID) = target {
            return .failure("no device tab holds reservation \(reservationID)")
        } else {
            let empty = emptyDeviceTab(in: task, besideTab: params.tabID, context: context)
            tab = empty.tab
            created = empty.created
        }
        let displayName = params.displayName ?? target.fallbackName
        if tab.deviceTarget == nil { tab.setDevice(target, displayName: displayName) }
        deviceSessions.existingSession(for: tab.id)?.point(at: target, displayName: displayName)
        var response = CLIResponse.success
        response.tabID = tab.id
        response.created = created
        return response
    }

    /// A device tab with no device and no reservation starting, else a new one in the pane
    /// opposite the caller, behind the selection.
    private func emptyDeviceTab(in task: WorkTask, besideTab callerTabID: UUID, context: ModelContext) -> (tab: TaskTab, created: Bool) {
        let empty = task.orderedTabs.first { tab in
            tab.kind == .device && tab.deviceTarget == nil && !deviceSessions.canEndReservation(for: tab.id)
                && !deviceLeases.isClaiming(deviceTab: tab.id)
        }
        if let empty { return (empty, false) }
        return (TaskStore.addDeviceTab(to: task, besideTab: callerTabID, in: context), true)
    }

    /// How long `reserveDevice` may take before it gives up rather than reserve: past
    /// `SocketDeviceAppClient.replyTimeout`, the claimant has stopped waiting for the answer.
    static let reserveDeadline: TimeInterval = 25

    /// Answers once the claim is recorded; `plume devices` waits on the registry for the device.
    private func reserveDevice(_ params: CLIRequest.ReserveDevice) async -> CLIResponse {
        let started = clock()
        guard currentTask(ofTab: params.tabID) != nil else {
            return .failure("no Plume tab \(params.tabID.uuidString)")
        }
        guard let socket = deviceLeases.appSocket else {
            return .failure("this Plume isn't tracking device leases")
        }
        let projectID: String
        if let given = params.projectID {
            projectID = given
        } else if let remembered = await remoteDevices.project() {
            projectID = remembered
        } else {
            return .failure("no Device Streaming project: sign in and pick one in a device tab's Remote section")
        }
        let modelID: String
        var catalog = RemoteDeviceCatalog.shared.models
        if let given = params.model {
            modelID = given
        } else if let form = params.form {
            catalog = await remoteDevices.models()
            guard let chosen = RemoteDeviceModel.choose(form: form, from: catalog, recent: remoteDevices.recentModel()) else {
                let options = catalog.isEmpty ? "" : ", one of: " + catalog.map(\.id).joined(separator: ", ")
                return .failure("Device Streaming offers no \(form.rawValue); pass --model=<codename/api>\(options)")
            }
            modelID = chosen.id
        } else if let recent = remoteDevices.recentModel() {
            modelID = recent
        } else {
            let offered = await remoteDevices.models().map(\.id)
            let options = offered.isEmpty ? "" : ", one of: " + offered.joined(separator: ", ")
            return .failure("no device model given and none reserved before; pass --model=<codename/api> or --form\(options)")
        }
        let model = catalog.first { $0.id == modelID }
        let form = params.form ?? model?.formFactor.deviceForm
        // The awaits above can outlast the caller or move it to another task.
        guard clock().timeIntervalSince(started) < Self.reserveDeadline else {
            return .failure("loading the Device Streaming catalog took too long; try again")
        }
        guard let (task, context) = currentTask(ofTab: params.tabID) else {
            return .failure("no Plume tab \(params.tabID.uuidString)")
        }
        let owner = DeviceLeaseOwner.tab(id: params.tabID, app: socket)
        // A second `plume devices claim` from the same tab, racing the first, waits on its claim.
        if let existing = deviceLeases.claim(ownedBy: owner) {
            if let model = params.model, model != existing.model {
                return .failure("this tab is already reserving \(existing.model); release it before reserving \(model)")
            }
            if let wanted = params.form, let reserving = existing.form, wanted != reserving {
                return .failure(
                    "this tab is already reserving \(existing.model), a \(reserving.rawValue); release it before reserving a \(wanted.rawValue)"
                )
            }
            do {
                try await deviceLeases.rejoin(existing)
            } catch {
                return .failure("couldn't record the claim: \(Devices.describe(error))")
            }
            var response = CLIResponse.success
            response.tabID = existing.deviceTabID
            response.created = false
            response.claimID = existing.id
            return response
        }
        // From here to `beginClaim` holding the claim there is no suspension, so a concurrent
        // request can't pick the same tab.
        let (tab, created) = emptyDeviceTab(in: task, besideTab: params.tabID, context: context)
        let claim = RemoteClaim(
            owner: owner,
            deviceTabID: tab.id,
            deviceTabCreated: created,
            model: modelID,
            form: form,
            projectID: projectID,
            ttl: params.ttl ?? DevicePool.defaultTTL,
            worktree: params.worktree,
            branch: params.branch
        )
        do {
            try await deviceLeases.beginClaim(claim)
        } catch {
            if created { closeTab(tab.id) }
            return .failure("couldn't record the claim: \(Devices.describe(error))")
        }
        let displayName = model?.name ?? modelID
        remoteDevices.reserve(tab, modelID, displayName, projectID)
        var response = CLIResponse.success
        response.tabID = tab.id
        response.created = created
        response.claimID = claim.id
        return response
    }

    private func releaseDevice(_ params: CLIRequest.ReleaseDevice) async -> CLIResponse {
        do {
            guard try await deviceLeases.releaseLease(params.key) != nil else {
                return .failure("this Plume holds no lease on \(params.key)")
            }
            return .success
        } catch {
            return .failure(Devices.describe(error))
        }
    }

    private func extendDevice(_ params: CLIRequest.ExtendDevice) async -> CLIResponse {
        do {
            try await deviceLeases.extendLease(params.key, ttl: params.ttl)
            return .success
        } catch {
            return .failure(Devices.describe(error))
        }
    }

    /// A Wi-Fi serial becomes the `wifi:` identifier a picked tab persists, so a tab already
    /// showing the phone is found.
    private func deviceTarget(_ params: CLIRequest.ShowDevice) async -> DeviceTarget? {
        switch params.kind {
        case .emulator: return params.avdID.map { .emulator(avdID: $0) }
        case .physical:
            guard let serial = params.serial else { return nil }
            return .physical(serial: await physicalDiscovery.resolvedIdentifier(forSerial: serial))
        case .remote: return params.reservationID.map { .remote(reservationID: $0) }
        }
    }

    /// A physical tab matches by the phone's serial number when known, so a USB tab and a Wi-Fi
    /// request for the same phone, or a tab saved under a Wi-Fi address, are one device.
    private func isSameDevice(_ tabTarget: DeviceTarget, _ target: DeviceTarget) -> Bool {
        guard case .physical(let tabIdentifier) = tabTarget, case .physical(let identifier) = target else {
            return tabTarget == target
        }
        return physicalDiscovery.namesSamePhone(tabIdentifier, identifier)
    }

    /// The worktree already exists, since `wt` made it; this only opens a
    /// task on it. An unknown caller puts the task outside any group rather
    /// than failing, because the worktree is there either way.
    private func newTask(_ params: CLIRequest.NewTask) async -> CLIResponse {
        let path = params.worktreePath
        guard path.hasPrefix("/") else {
            return .failure("worktreePath must be an absolute path: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("no such directory: \(path)")
        }
        guard let checkout = await inspectCheckout(path),
              Self.resolvedPath(checkout.facts.checkoutRoot) == Self.resolvedPath(path)
        else { return .failure("not a git worktree: \(path)") }

        let windows = frontmostFirst
        let callerTaskID = params.taskID ?? params.tabID.flatMap { tabID in
            windows.lazy.compactMap { $0.taskIDForTab(tabID) }.first
        }
        let caller = callerTaskID.flatMap { id in
            windows.lazy.compactMap { window in window.task(id).map { (task: $0, context: window.context) } }.first
        }
        guard let context = caller?.context ?? windows.first?.context else {
            return .failure("no Plume window is open")
        }
        let liveTasks = ((try? context.fetch(FetchDescriptor<WorkTask>())) ?? []).filter { !$0.isArchived }
        // A client that timed out and retried would otherwise get a second
        // task for the same worktree.
        let resolved = Self.resolvedPath(path)
        if let existing = liveTasks.first(where: { $0.workingDirectoryPath.map(Self.resolvedPath) == resolved }) {
            if params.select { windows.first?.reveal(existing.id) }
            var response = CLIResponse.success
            response.taskID = existing.id
            return response
        }
        let group = caller?.task.group
        let siblings = liveTasks.filter { $0.group?.id == group?.id }
        let task = TaskStore.createTask(
            in: context, title: (path as NSString).lastPathComponent, group: group, siblings: siblings
        )
        task.workingDirectoryPath = path
        task.repoPath = ProjectRoot.repositoryDirectory(forRoot: checkout.facts.projectRoot)
        task.branchName = checkout.branch
        // Deleting a worktree task offers to remove the worktree, which the
        // main checkout must never be.
        task.workspaceKind = checkout.facts.isWorktree ? .worktree : .directory
        if params.select { windows.first?.reveal(task.id) }
        var response = CLIResponse.success
        response.taskID = task.id
        return response
    }

    /// Deletes a task through `TaskStore`, which closes its terminals. A no-op when no open
    /// window's store has it.
    func deleteTask(_ id: UUID) {
        for registration in frontmostFirst {
            let tasks = (try? registration.context.fetch(FetchDescriptor<WorkTask>())) ?? []
            guard let task = tasks.first(where: { $0.id == id }) else { continue }
            TaskStore.delete(task, in: registration.context)
            return
        }
    }

    /// Closes a tab through `TaskStore`, as its close button would. A no-op when no open window's
    /// store has it.
    /// Leaves an archived task's tabs alone, since restoring the task brings them back.
    func closeTab(_ id: UUID) {
        for registration in frontmostFirst {
            let tabs = (try? registration.context.fetch(FetchDescriptor<TaskTab>(predicate: #Predicate { $0.id == id }))) ?? []
            guard let tab = tabs.first else { continue }
            if tab.task?.isArchived != true { TaskStore.closeTab(tab, in: registration.context) }
            return
        }
    }

    func hasLiveTab(_ id: UUID) -> Bool {
        guard let (task, _) = currentTask(ofTab: id) else { return false }
        return !task.isArchived
    }

    /// Git answers with symlinks resolved, so `/var/…` must match
    /// `/private/var/…`.
    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func openSettings(_ params: CLIRequest.OpenSettings) -> CLIResponse {
        var pane: SettingsPane?
        if let section = params.section {
            guard let named = SettingsPane(rawValue: section) else {
                return .failure("no settings section \(section)")
            }
            pane = named
        }
        guard let window = frontmostFirst.first else {
            return .failure("no Plume window is open")
        }
        if let pane { settingsDefaults.set(pane.rawValue, forKey: SettingsPane.selectionKey) }
        activateApp()
        window.openSettings()
        return .success
    }

    private func newTab(_ params: CLIRequest.NewTab) -> CLIResponse {
        let windows = frontmostFirst
        let taskID: UUID
        if let requested = params.taskID {
            taskID = requested
        } else if let tabID = params.tabID {
            guard let owner = windows.lazy.compactMap({ $0.taskIDForTab(tabID) }).first else {
                return .failure("no Plume tab \(tabID.uuidString)")
            }
            taskID = owner
        } else {
            return .failure("tab.new needs a taskID or tabID")
        }
        guard let (task, context) = windows.lazy.compactMap({ window in window.task(taskID).map { ($0, window.context) } }).first else {
            return .failure("no Plume task \(taskID.uuidString)")
        }
        if let directory = params.directory {
            guard directory.hasPrefix("/") else {
                return .failure("directory must be an absolute path: \(directory)")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .failure("no such directory: \(directory)")
            }
        }
        let tab = Self.addTerminalTab(
            to: task, directory: params.directory, select: params.select, in: context, directories: directories
        )
        if params.select { windows.first?.reveal(taskID) }
        var response = CLIResponse.success
        response.tabID = tab.id
        return response
    }

    /// Unless asked to select it, the new tab opens behind whatever the user
    /// has selected, since a script rarely means to steal focus.
    static func addTerminalTab(
        to task: WorkTask,
        directory: String?,
        select: Bool,
        in context: ModelContext,
        directories: TabDirectoryStore = .shared
    ) -> TaskTab {
        let previous = task.selectedTabID.flatMap { id in task.tabs.first { $0.id == id } }
        let tab = TaskStore.addTab(to: task, kind: .terminal, in: context)
        directories.setDirectory(directory, forTab: tab)
        if !select, let previous {
            TaskStore.selectTab(previous, in: task)
        }
        return tab
    }
}
