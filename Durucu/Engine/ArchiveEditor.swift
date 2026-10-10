import Foundation
import CLibArchive

/// Changes to apply to an existing archive.
struct ArchiveEdit: Sendable {
    /// Normalized archive paths to drop. A folder takes its whole subtree with it.
    var deletions: Set<String> = []
    /// Items to write, with `archivePath` relative to the archive root.
    var additions: [SourceItem] = []
}

/// libarchive cannot modify an archive in place, so an edit streams every surviving entry
/// into a new archive next to the original, appends the additions, and only then swaps the
/// files. The previous version goes to the Trash, so nothing is lost if the edit was a mistake.
enum ArchiveEditor {
    static func apply(
        _ edit: ArchiveEdit,
        to url: URL,
        format: OutputFormat,
        level: CompressionLevel,
        password: String?,
        progress: (@Sendable (CompressionProgress) -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path) else {
            throw ArchiveError.writeFailed("“\(folder.lastPathComponent)” klasörüne yazılamıyor.")
        }

        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).durucu-edit")
        try? fileManager.removeItem(at: temporary)
        do {
            try rewrite(url, into: temporary, edit: edit, format: format, level: level, password: password, progress: progress)
            if Task.isCancelled { throw ArchiveError.cancelled }
            try swap(url, with: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func rewrite(
        _ url: URL,
        into temporary: URL,
        edit: ArchiveEdit,
        format: OutputFormat,
        level: CompressionLevel,
        password: String?,
        progress: (@Sendable (CompressionProgress) -> Void)?
    ) throws {
        let legacyNames = ZipCentralDirectory.read(url: url)?.hasLegacyNames ?? false
        let reader = try ArchiveReader.openForReading(url, password: password, legacyNames: legacyNames)
        defer { archive_read_free(reader) }
        let output = try ArchiveOutput(url: temporary, format: format, level: level, password: password)

        let added = Set(edit.additions.map { normalized($0.archivePath) })
        let archiveBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let addedBytes = edit.additions.reduce(Int64(0)) { $0 + ($1.kind == .file ? $1.size : 0) }
        // Existing entries are measured in compressed bytes read, additions in bytes written.
        var meter = ProgressMeter(total: archiveBytes + addedBytes, report: progress)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: ArchiveWriter.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entry: OpaquePointer?
        var consumed: Int64 = 0
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw LibArchive.readError(reader, hadPassword: password != nil) }
            guard let entry else { continue }
            if Task.isCancelled { throw ArchiveError.cancelled }

            let path = ArchiveReader.entryPath(entry)
            if path.isEmpty || isDeleted(path, edit.deletions) || added.contains(normalized(path)) {
                archive_read_data_skip(reader)
                continue
            }

            let type = Int32(archive_entry_filetype(entry))
            let kind: ArchiveEntry.Kind = type == AE_IFDIR ? .directory : type == AE_IFLNK ? .symlink : .file
            var hardlink: String?
            if let raw = archive_entry_hardlink(entry) {
                let target = ArchivePath.normalize(ArchivePath.decode(raw))
                if isDeleted(target, edit.deletions) || added.contains(normalized(target)) {
                    archive_read_data_skip(reader)
                    continue
                }
                hardlink = target
            }

            try output.begin(
                path: path,
                kind: kind,
                size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
                permissions: archive_entry_perm(entry),
                modified: (Int(archive_entry_mtime(entry)), Int(archive_entry_mtime_nsec(entry))),
                linkTarget: archive_entry_symlink(entry).map(ArchivePath.decode),
                hardlink: hardlink
            )

            if kind == .file, hardlink == nil {
                while true {
                    let count = archive_read_data(reader, buffer, ArchiveWriter.bufferSize)
                    if count == 0 { break }
                    if count < 0 { throw LibArchive.readError(reader, hadPassword: password != nil) }
                    try output.write(buffer, count: count)
                    if Task.isCancelled { throw ArchiveError.cancelled }
                    let position = archive_filter_bytes(reader, -1)
                    meter.advance(max(0, position - consumed), item: ArchivePath.name(of: path))
                    consumed = max(consumed, position)
                }
            }
        }

        for item in edit.additions {
            try ArchiveWriter.write(item, to: output, buffer: buffer, meter: &meter)
        }
        try output.finish()
        meter.finish()
    }

    /// Puts the new archive in place and moves the previous version to the Trash.
    private static func swap(_ url: URL, with temporary: URL) throws {
        let fileManager = FileManager.default
        let backupName = "\(FileNaming.baseName(of: url)) (önceki sürüm)\(url.lastPathComponent.dropFirst(FileNaming.baseName(of: url).count))"
        let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
        try? fileManager.removeItem(at: backup)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: backupName, options: [.withoutDeletingBackupItem])
        } catch {
            throw ArchiveError.writeFailed("Yeni arşiv yerine konamadı. \(error.localizedDescription)")
        }
        if fileManager.fileExists(atPath: backup.path) {
            try? fileManager.trashItem(at: backup, resultingItemURL: nil)
        }
    }

    /// True for deleted paths, anything inside a deleted folder, and the Finder
    /// `__MACOSX/…/._name` companions of either.
    static func isDeleted(_ path: String, _ deletions: Set<String>) -> Bool {
        guard !deletions.isEmpty else { return false }
        if isInside(path, deletions) { return true }
        guard path.hasPrefix("__MACOSX/") else { return false }
        let companion = String(path.dropFirst("__MACOSX/".count))
        let name = ArchivePath.name(of: companion)
        guard name.hasPrefix("._") else { return isInside(companion, deletions) }
        let parent = ArchivePath.parent(of: companion)
        let original = String(name.dropFirst(2))
        return isInside(parent.isEmpty ? original : "\(parent)/\(original)", deletions)
    }

    private static func isInside(_ path: String, _ deletions: Set<String>) -> Bool {
        var cursor = Substring(path)
        while true {
            if deletions.contains(String(cursor)) { return true }
            guard let slash = cursor.lastIndex(of: "/") else { return false }
            cursor = cursor[..<slash]
        }
    }

    private static func normalized(_ path: String) -> String {
        ArchivePath.normalize(path).precomposedStringWithCanonicalMapping
    }
}
