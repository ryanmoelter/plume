import Darwin
import Foundation
import os

@MainActor
final class CodexDetachedProcessMonitor {
    private let tabID: UUID
    private let tracker: CodexDetachedProcessTracker
    private let generation: UUID
    private var lease: Lease?
    private var stopped = false
    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var dirty = false
    private var graceScans = 0
    private var members: [ProcessIdentity] = []
    private var groups: [Int32: CodexDetachedProcess] = [:]

    init(tabID: UUID, tracker: CodexDetachedProcessTracker = .shared) {
        self.tabID = tabID
        self.tracker = tracker
        generation = tracker.begin(tabID: tabID)
    }

    func prepare(configuration: JSONValue) async -> [String: JSONValue] {
        guard !stopped, lease == nil, Self.isCompatible(configuration) else { return [:] }
        do {
            let prepared = try await Task.detached { try Lease.create(configuration: configuration) }.value
            guard !stopped else {
                await Task.detached { prepared.remove() }.value
                return [:]
            }
            lease = prepared
            return prepared.overrides
        } catch {
            Log.agent.error("Codex detached-work tracking could not prepare its marker")
            return [:]
        }
    }

    func refresh() {
        graceScans = 3
        requestScan()
    }

    private func requestScan() {
        guard !stopped, let lease else { return }
        pollTask?.cancel()
        pollTask = nil
        if scanTask != nil {
            dirty = true
            return
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                dirty = false
                let previous = members
                let found = await Task.detached { Self.scan(marker: lease.marker, retaining: previous) }.value
                guard !stopped, !Task.isCancelled else { return }
                members = found
                groups = Self.groupedProcesses(found, previous: previous, anchors: groups)
                tracker.replace(tabID: tabID, generation: generation, processes: Array(groups.values))
            } while dirty && !Task.isCancelled
            scanTask = nil
            if !members.isEmpty || graceScans > 0 {
                let delay: Duration = members.isEmpty ? .milliseconds(250) : .seconds(1)
                if members.isEmpty { graceScans -= 1 }
                pollTask = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    self?.requestScan()
                }
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        scanTask?.cancel()
        pollTask?.cancel()
        tracker.end(tabID: tabID, generation: generation)
        members = []
        groups = [:]
        if let lease {
            self.lease = nil
            Task.detached { lease.remove() }
        }
    }

    nonisolated static func isCompatible(_ configuration: JSONValue, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let policy = configuration["shell_environment_policy"]
        guard policy?["experimental_use_profile"]?.boolValue != true,
              policy?["inherit"]?.stringValue.map({ $0 == "all" }) ?? true,
              policy?["exclude"]?.arrayValue?.isEmpty ?? true,
              policy?["include_only"]?.arrayValue?.isEmpty ?? true,
              policy?["filters"]?.objectValue?.isEmpty ?? true else { return false }
        let shell = policy?["set"]?["SHELL"]?.stringValue ?? environment["SHELL"] ??
            getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }
        return shell.map { URL(fileURLWithPath: $0).lastPathComponent == "zsh" } == true
    }

    nonisolated struct Lease: Sendable {
        let directory: URL
        let marker: URL
        let overrides: [String: JSONValue]

        static func create(configuration: JSONValue, baseDirectory: URL = FileManager.default.temporaryDirectory) throws -> Lease {
            let directory = baseDirectory.appendingPathComponent("plume-codex-work-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let marker = directory.appendingPathComponent("owner")
                guard FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o400]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try shim.write(to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
                var overrides: [String: JSONValue] = [
                    "shell_environment_policy.set.ZDOTDIR": .string(directory.path),
                    "shell_environment_policy.set.PLUME_CODEX_MARKER": .string(marker.path)
                ]
                if let original = configuration["shell_environment_policy"]?["set"]?["ZDOTDIR"]?.stringValue {
                    overrides["shell_environment_policy.set.PLUME_CODEX_ORIGINAL_ZDOTDIR"] = .string(original)
                    overrides["shell_environment_policy.set.PLUME_CODEX_ZDOTDIR_SET"] = .string("1")
                }
                return Lease(directory: directory, marker: marker, overrides: overrides)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        static let shim = """
        if [[ "${PLUME_CODEX_ZDOTDIR_SET-0}" == 1 ]]; then
          ZDOTDIR="${PLUME_CODEX_ORIGINAL_ZDOTDIR-}"
        else
          unset ZDOTDIR
        fi
        if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
          source "${ZDOTDIR-$HOME}/.zshenv"
        fi
        if [[ -n "${CODEX_THREAD_ID-}" && -r "${PLUME_CODEX_MARKER-}" ]]; then
          exec {__plume_codex_marker_fd}<"$PLUME_CODEX_MARKER"
        fi
        """
    }

    nonisolated struct ProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let group: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let parent: UInt32

        var id: String { "\(pid)/\(seconds)/\(microseconds)" }
        var startedAt: Date { Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000) }

        static func read(_ pid: Int32) -> ProcessIdentity? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_status != 5 else { return nil }
            return ProcessIdentity(pid: pid, group: Int32(bitPattern: info.pbi_pgid), seconds: info.pbi_start_tvsec,
                                   microseconds: info.pbi_start_tvusec, parent: info.pbi_ppid)
        }
    }

    nonisolated static func groupedProcesses(_ members: [ProcessIdentity], previous: [ProcessIdentity], anchors: [Int32: CodexDetachedProcess]) -> [Int32: CodexDetachedProcess] {
        let previousIDs = Dictionary(grouping: previous, by: \.group).mapValues { Set($0.map(\.id)) }
        return Dictionary(grouping: members, by: \.group).mapValues { values in
            let first = values.min { $0.startedAt < $1.startedAt }!
            if values.contains(where: { previousIDs[first.group]?.contains($0.id) == true }), let anchor = anchors[first.group] {
                return anchor
            }
            return CodexDetachedProcess(id: first.id, startedAt: first.startedAt)
        }
    }

    nonisolated static func scan(marker: URL, retaining previous: [ProcessIdentity]) -> [ProcessIdentity] {
        var found: [Int32: ProcessIdentity] = [:]
        for previous in previous {
            if let current = ProcessIdentity.read(previous.pid), current.id == previous.id { found[current.pid] = current }
        }
        guard let pids = markerPIDs(marker) else { return found.values.sorted { $0.id < $1.id } }
        let candidates = pids.compactMap(ProcessIdentity.read).filter { $0.parent == 1 }
        guard let confirmed = markerPIDs(marker) else { return found.values.sorted { $0.id < $1.id } }
        for candidate in candidates where confirmed.contains(candidate.pid) {
            if let leader = ProcessIdentity.read(candidate.group), leader.group == candidate.group, leader.parent != 1 { continue }
            if let current = ProcessIdentity.read(candidate.pid), current.id == candidate.id { found[current.pid] = current }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    nonisolated private static func markerPIDs(_ marker: URL) -> Set<Int32>? {
        var pids = [Int32](repeating: 0, count: 4096)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let bytes = marker.path.withCString { path in
            pids.withUnsafeMutableBytes { buffer in
                proc_listpidspath(1, 0, path, 0, buffer.baseAddress, capacity)
            }
        }
        guard bytes >= 0, bytes < capacity else { return nil }
        return Set(pids.prefix(Int(bytes) / MemoryLayout<Int32>.size))
    }
}
