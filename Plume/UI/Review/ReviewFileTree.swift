import Foundation

/// A folder's files as a tree, with each changed file's kind and a count of
/// changes under every folder. Built off the main actor, once per listing.
nonisolated struct ReviewFileTree: Sendable, Equatable {
    struct Node: Sendable, Equatable, Identifiable {
        let path: String
        let name: String
        let isDirectory: Bool
        var id: String { path }
    }

    /// Children of each folder, keyed by its path; the root is "".
    private(set) var children: [String: [Node]] = [:]
    private(set) var changes: [String: DiffChangeKind] = [:]
    /// How many changed files sit under each folder.
    private(set) var changedDescendants: [String: Int] = [:]

    static let empty = ReviewFileTree()

    init() {}

    init(paths: [String], files: [DiffFileSummary]) {
        for file in files { changes[file.path] = file.kind }
        var folders: [String: Set<String>] = [:]
        var leaves: [String: [String]] = [:]

        for path in Set(paths).union(changes.keys) {
            let components = path.split(separator: "/").map(String.init)
            var parent = ""
            for (index, component) in components.enumerated() {
                let current = parent.isEmpty ? component : "\(parent)/\(component)"
                if index == components.count - 1 {
                    leaves[parent, default: []].append(current)
                } else {
                    folders[parent, default: []].insert(current)
                }
                parent = current
            }
        }

        for path in changes.keys {
            var folder = (path as NSString).deletingLastPathComponent
            while true {
                changedDescendants[folder, default: 0] += 1
                if folder.isEmpty { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }

        for parent in Set(folders.keys).union(leaves.keys) {
            let directories = (folders[parent] ?? []).sorted(by: Self.ordered).map {
                Node(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: true)
            }
            let files = (leaves[parent] ?? []).sorted(by: Self.ordered).map {
                Node(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false)
            }
            children[parent] = directories + files
        }
    }

    private static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    struct Row: Identifiable, Equatable {
        let node: Node
        let depth: Int
        let isExpanded: Bool
        var id: String { node.path }
    }

    /// The rows a reader sees, walking only into expanded folders.
    func visibleRows(isExpanded: (String) -> Bool) -> [Row] {
        var rows: [Row] = []
        var stack: [(Node, Int)] = (children[""] ?? []).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            let expanded = node.isDirectory && isExpanded(node.path)
            rows.append(Row(node: node, depth: depth, isExpanded: expanded))
            if expanded {
                stack += (children[node.path] ?? []).reversed().map { ($0, depth + 1) }
            }
        }
        return rows
    }
}
