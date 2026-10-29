import Darwin
import Foundation

/// One tracked branch. `base` is the commit of `parent` the branch was last
/// stacked on: the lower bound for `git rebase --onto`.
nonisolated struct StackEntry: Equatable, Sendable {
    var parent: String
    var base: String
    /// Keys besides `parent` and `base`, kept so a rewrite round-trips them.
    var extra: [StackJSONMember]

    init(parent: String, base: String, extra: [StackJSONMember] = []) {
        self.parent = parent
        self.base = base
        self.extra = extra
    }
}

/// Every tracked branch by name. A stack is a tree derived from the parent
/// pointers, rooted at a branch whose parent isn't tracked.
typealias StackBranches = [String: StackEntry]

/// `branches.json`: `{"version": 2, "branches": {name: {"parent", "base"}}}`.
nonisolated enum StackStateCodec {
    static let currentVersion = 2

    enum DecodeError: Error, Equatable {
        case unreadable(String)
        /// Written by a newer `stack`; never overwrite it.
        case tooNew(Int)
    }

    static func encode(_ branches: StackBranches) -> String {
        let entries = branches.map { name, entry in
            StackJSONMember(name, .object([
                StackJSONMember("parent", .string(entry.parent)),
                StackJSONMember("base", .string(entry.base)),
            ] + entry.extra))
        }
        let document = StackJSON.object([
            StackJSONMember("version", .int(currentVersion)),
            StackJSONMember("branches", .object(entries)),
        ])
        return document.rendered(sortKeys: true) + "\n"
    }

    /// The entries in file order, which decides the winner when legacy
    /// files name a branch twice.
    static func decode(_ data: Data) throws -> [(name: String, entry: StackEntry)] {
        let document: StackJSON
        do {
            document = try StackJSON.parse(data)
        } catch let error as StackJSON.ParseError {
            throw DecodeError.unreadable(error.message)
        }
        guard case .object = document else { throw DecodeError.unreadable("not a JSON object") }
        switch document["version"] {
        case nil: break
        case .int(let version)?:
            if version > currentVersion { throw DecodeError.tooNew(version) }
        default: throw DecodeError.unreadable("'version' is not a number")
        }
        guard case .object(let members)? = document["branches"] else {
            throw DecodeError.unreadable("'branches'")
        }
        return try members.map { member in
            guard case .object(let fields) = member.value,
                  case .string(let parent)? = member.value["parent"],
                  case .string(let base)? = member.value["base"]
            else { throw DecodeError.unreadable("entry '\(member.key)' needs a parent and a base") }
            let extra = fields.filter { $0.key != "parent" && $0.key != "base" }
            return (member.key, StackEntry(parent: parent, base: base, extra: extra))
        }
    }
}

/// The state directory, `<git-common-dir>/stack`, shared by every worktree.
nonisolated final class StackStateStore {
    static let fileName = "branches.json"

    let directory: String

    init(directory: String) {
        self.directory = directory
    }

    var stateFile: String { "\(directory)/\(Self.fileName)" }

    struct LoadResult: Equatable {
        var branches: StackBranches
        /// Legacy files were merged or deleted branches pruned, in memory
        /// only.
        var dirty: Bool
    }

    /// Merges every `*.json` in filename order, the first entry for a
    /// branch winning, then prunes branches with no local ref: their
    /// children move to the pruned branch's parent and keep their base.
    func load(localBranches: Set<String>, warn: (String) -> Void) throws -> LoadResult {
        var order: [String] = []
        var branches: StackBranches = [:]
        var dirty = false
        for name in stateFileNames() {
            let path = "\(directory)/\(name)"
            let records: [(name: String, entry: StackEntry)]
            do {
                records = try StackStateCodec.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            } catch StackStateCodec.DecodeError.tooNew(let version) {
                throw CLIFailure("\(path) has state version \(version) — this stack binary is too old")
            } catch StackStateCodec.DecodeError.unreadable(let reason) {
                warn("ignoring unreadable state file \(path): \(reason)")
                continue
            } catch {
                warn("ignoring unreadable state file \(path): \(error.localizedDescription)")
                continue
            }
            if name != Self.fileName { dirty = true }
            for record in records {
                if branches[record.name] != nil {
                    warn("branch '\(record.name)' appears in multiple state files — keeping the first entry")
                    continue
                }
                order.append(record.name)
                branches[record.name] = record.entry
            }
        }
        for name in order where !localBranches.contains(name) {
            guard let parent = branches[name]?.parent else { continue }
            for child in branches.keys where branches[child]?.parent == name {
                branches[child]?.parent = parent
            }
            branches[name] = nil
            dirty = true
            warn("pruned deleted branch '\(name)' from stack state")
        }
        return LoadResult(branches: branches, dirty: dirty)
    }

    /// Writes `branches.json` atomically, or removes it when there is
    /// nothing to track. Legacy files are retired; a file that can't be
    /// read is moved aside rather than lost.
    func save(_ branches: StackBranches, warn: (String) -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for name in stateFileNames() {
            let path = "\(directory)/\(name)"
            switch readability(of: path) {
            case .readable:
                if name != Self.fileName { try manager.removeItem(atPath: path) }
            case .tooNew(let version):
                throw CLIFailure("\(path) has state version \(version) — this stack binary is too old")
            case .unreadable:
                let aside = "\(path).unreadable-\(Self.timestamp())"
                try manager.moveItem(atPath: path, toPath: aside)
                warn("moved unreadable state file aside to \(aside)")
            }
        }
        if branches.isEmpty {
            try? manager.removeItem(atPath: stateFile)
            return
        }
        var template = Array("\(directory)/.branches.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else {
            throw CLIFailure("could not write \(stateFile): \(String(cString: strerror(errno)))")
        }
        let temporary = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(StackStateCodec.encode(branches).utf8))
            try handle.close()
            guard rename(temporary, stateFile) == 0 else {
                throw CLIFailure("could not write \(stateFile): \(String(cString: strerror(errno)))")
            }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// Runs `body` holding an exclusive `flock` on `<directory>/lock`. Not
    /// reentrant: a nested call deadlocks.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open("\(directory)/lock", O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CLIFailure("could not open \(directory)/lock: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw CLIFailure("could not lock \(directory)/lock: \(String(cString: strerror(errno)))")
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func stateFileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted { StackJSON.codePointPrecedes($0, $1) }
    }

    private enum Readability {
        case readable
        case tooNew(Int)
        case unreadable
    }

    private func readability(of path: String) -> Readability {
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        do {
            _ = try StackStateCodec.decode(data)
            return .readable
        } catch StackStateCodec.DecodeError.tooNew(let version) {
            return .tooNew(version)
        } catch {
            return .unreadable
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
