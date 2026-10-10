import Foundation
import UniformTypeIdentifiers

struct ArchiveNode: Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool
    /// A folder the archive never lists itself; it only appears in its children's paths.
    var isImplicit: Bool
    var size: Int64
    var compressedSize: Int64?
    var modified: Date?
    var isEncrypted: Bool
    var method: String?
    var crc32: UInt32?
    var linkTarget: String?
    var permissions: UInt16
    var parent: Int?
    var children: [Int] = []
    var fileCount = 0
    var folderCount = 0
    var kindDescription: String

    var compressedSortKey: Int64 { compressedSize ?? -1 }
    var modifiedSortKey: Date { modified ?? .distantPast }

    /// Share of the original size saved by compression (0…1), or -1 when unknown.
    var savings: Double {
        guard let compressedSize, size > 0 else { return -1 }
        return max(0, 1 - Double(compressedSize) / Double(size))
    }

    var parentPath: String { ArchivePath.parent(of: path) }
}

struct FolderOutline: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    var children: [FolderOutline]?
}

struct ArchiveTree: Sendable {
    static let rootID = 0

    private(set) var nodes: [ArchiveNode]

    static let empty = ArchiveTree(nodes: [
        ArchiveNode(id: 0, name: "", path: "", isDirectory: true, isSymlink: false, isImplicit: true, size: 0,
                    compressedSize: nil, modified: nil, isEncrypted: false, method: nil, crc32: nil, linkTarget: nil,
                    permissions: 0o755, parent: nil, kindDescription: "Arşiv"),
    ])

    var root: ArchiveNode { nodes[Self.rootID] }

    func node(_ id: Int) -> ArchiveNode? {
        nodes.indices.contains(id) ? nodes[id] : nil
    }

    func children(of id: Int) -> [ArchiveNode] {
        node(id)?.children.map { nodes[$0] } ?? []
    }

    /// Root first, `id` last.
    func lineage(of id: Int) -> [ArchiveNode] {
        var result: [ArchiveNode] = []
        var cursor: Int? = id
        while let current = cursor, let node = node(current) {
            result.append(node)
            cursor = node.parent
        }
        return result.reversed()
    }

    func search(_ query: String, limit: Int = 5000) -> [ArchiveNode] {
        var results: [ArchiveNode] = []
        for node in nodes.dropFirst() where node.name.localizedStandardContains(query) {
            results.append(node)
            if results.count == limit { break }
        }
        return results
    }

    func folderOutline(rootName: String) -> [FolderOutline] {
        func outline(_ id: Int) -> FolderOutline {
            let folders = nodes[id].children
                .filter { nodes[$0].isDirectory }
                .sorted { nodes[$0].name.localizedStandardCompare(nodes[$1].name) == .orderedAscending }
                .map(outline)
            return FolderOutline(id: id, name: id == Self.rootID ? rootName : nodes[id].name,
                                 children: folders.isEmpty ? nil : folders)
        }
        return [outline(Self.rootID)]
    }

    static func build(from entries: [ArchiveEntry], includeMacMetadata: Bool) -> ArchiveTree {
        var nodes = empty.nodes
        var directories: [String: Int] = ["": rootID]
        var kinds: [String: String] = [:]

        func kind(for name: String) -> String {
            let ext = (name as NSString).pathExtension.lowercased()
            if let cached = kinds[ext] { return cached }
            let description = UTType(filenameExtension: ext)?.localizedDescription ?? "Belge"
            kinds[ext] = description
            return description
        }

        func directory(_ path: String) -> Int {
            if let existing = directories[path] { return existing }
            let parent = directory(ArchivePath.parent(of: path))
            let id = nodes.count
            let name = ArchivePath.name(of: path)
            let isPackage = UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .package) ?? false
            nodes.append(ArchiveNode(
                id: id, name: name, path: path, isDirectory: true, isSymlink: false, isImplicit: true, size: 0,
                compressedSize: 0, modified: nil, isEncrypted: false, method: nil, crc32: nil, linkTarget: nil,
                permissions: 0o755, parent: parent, kindDescription: isPackage ? kind(for: name) : "Klasör"
            ))
            nodes[parent].children.append(id)
            directories[path] = id
            return id
        }

        for entry in entries {
            if !includeMacMetadata, ArchivePath.isMacMetadata(entry.path) { continue }
            if entry.kind == .directory {
                let id = directory(entry.path)
                nodes[id].isImplicit = false
                nodes[id].modified = entry.modified
                nodes[id].permissions = entry.permissions
                continue
            }
            let parent = directory(ArchivePath.parent(of: entry.path))
            let id = nodes.count
            let name = ArchivePath.name(of: entry.path)
            nodes.append(ArchiveNode(
                id: id, name: name, path: entry.path, isDirectory: false, isSymlink: entry.kind == .symlink,
                isImplicit: false, size: entry.size ?? 0, compressedSize: entry.compressedSize,
                modified: entry.modified, isEncrypted: entry.isEncrypted, method: entry.method, crc32: entry.crc32,
                linkTarget: entry.linkTarget, permissions: entry.permissions, parent: parent,
                kindDescription: entry.kind == .symlink ? "Sembolik bağlantı" : kind(for: name)
            ))
            nodes[parent].children.append(id)
        }

        // Children always come after their parent, so one reverse pass aggregates totals.
        for id in nodes.indices.reversed() where id != rootID {
            let child = nodes[id]
            guard let parent = child.parent else { continue }
            nodes[parent].size += child.size
            if let packed = child.compressedSize, let total = nodes[parent].compressedSize {
                nodes[parent].compressedSize = total + packed
            } else {
                nodes[parent].compressedSize = nil
            }
            nodes[parent].isEncrypted = nodes[parent].isEncrypted || child.isEncrypted
            if child.isDirectory {
                nodes[parent].fileCount += child.fileCount
                nodes[parent].folderCount += child.folderCount + 1
            } else {
                nodes[parent].fileCount += 1
            }
            if nodes[parent].isImplicit, let modified = child.modified,
               nodes[parent].modified.map({ modified > $0 }) ?? true {
                nodes[parent].modified = modified
            }
        }
        if nodes[rootID].children.isEmpty { nodes[rootID].compressedSize = nil }
        return ArchiveTree(nodes: nodes)
    }
}
