#if DEBUG
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

    /// The node that holds changed files outside `scope`.
    static let outsideScope = ".."

    /// `scope` is the folder the tree is rooted at, relative to the
    /// repository root, or empty for the root itself. Every node keeps its
    /// repository-relative path. Changed files outside `scope` sit under one
    /// `..` folder, which lists nothing else.
    init(paths: [String], files: [DiffFileSummary], scope: String = "") {
        for file in files { changes[file.path] = file.kind }
        let scopePrefix = scope.isEmpty ? "" : scope + "/"
        var folders: [String: Set<String>] = [:]
        var leaves: [String: [String]] = [:]

        /// The children key a folder's nodes are filed under: the scope is
        /// the root, and outside it the repository root is `..`.
        func key(_ folder: String, inScope: Bool) -> String {
            if inScope { return folder == scope ? "" : folder }
            return folder.isEmpty ? Self.outsideScope : folder
        }

        func insert(_ path: String, inScope: Bool) {
            let relative = inScope ? String(path.dropFirst(scopePrefix.count)) : path
            let components = relative.split(separator: "/").map(String.init)
            // `ls-files` lists a nested repository as `name/`.
            let endsInFile = !path.hasSuffix("/")
            var parent = inScope ? scope : ""
            for (index, component) in components.enumerated() {
                let current = parent.isEmpty ? component : "\(parent)/\(component)"
                if endsInFile, index == components.count - 1 {
                    leaves[key(parent, inScope: inScope), default: []].append(current)
                } else {
                    folders[key(parent, inScope: inScope), default: []].insert(current)
                }
                parent = current
            }
        }

        for path in Set(paths).union(changes.keys) {
            if path.hasPrefix(scopePrefix) {
                insert(path, inScope: true)
            } else if changes[path] != nil {
                insert(path, inScope: false)
            }
        }

        for path in changes.keys {
            let inScope = path.hasPrefix(scopePrefix)
            var folder = (path as NSString).deletingLastPathComponent
            while true {
                let key = key(folder, inScope: inScope)
                changedDescendants[key, default: 0] += 1
                if key == "" { break }
                if key == Self.outsideScope {
                    changedDescendants["", default: 0] += 1
                    break
                }
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
        if children[Self.outsideScope] != nil {
            children["", default: []].append(Node(path: Self.outsideScope, name: Self.outsideScope, isDirectory: true))
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
#endif
