import Foundation
import CLibArchive

struct ExtractionProgress: Sendable {
    var fraction: Double
    var currentItem: String
}

/// Which entries to extract and where each one lands, relative to the output folder.
struct ExtractionPlan: Sendable {
    /// Normalized archive path → relative output path, or `nil` to skip the entry.
    var map: @Sendable (String) -> String?
    /// Uncompressed bytes the plan covers; drives progress when known.
    var totalBytes: Int64
    var skipMacMetadata: Bool

    static func everything(totalBytes: Int64, skipMacMetadata: Bool) -> ExtractionPlan {
        ExtractionPlan(map: { $0 }, totalBytes: totalBytes, skipMacMetadata: skipMacMetadata)
    }
}

enum ArchiveReader {
    private static let blockSize = 128 * 1024

    // MARK: Listing

    static func list(url: URL, password: String?, progress: (@Sendable (Double) -> Void)? = nil) throws -> ArchiveInfo {
        let zipDirectory = ZipCentralDirectory.read(url: url)
        let archive = try openForReading(url, password: password, legacyNames: zipDirectory?.hasLegacyNames ?? false)
        defer { archive_read_free(archive) }

        let archiveSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var entries: [ArchiveEntry] = []
        var formatName = ""
        var lastReport = Date.distantPast
        var entry: OpaquePointer?

        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw LibArchive.readError(archive, hadPassword: password != nil) }
            guard let entry else { continue }

            if entries.isEmpty {
                formatName = archive_format_name(archive).map { String(cString: $0) } ?? ""
                if formatName == "raw", archive_filter_count(archive) <= 1 { throw ArchiveError.notAnArchive }
            }

            var item = makeEntry(entry)
            if formatName == "raw" { item.path = url.deletingPathExtension().lastPathComponent }
            if !item.path.isEmpty { entries.append(item) }

            if archive_read_data_skip(archive) < ARCHIVE_WARN {
                throw LibArchive.readError(archive, hadPassword: password != nil)
            }
            if Task.isCancelled { throw ArchiveError.cancelled }
            if let progress, archiveSize > 0, Date().timeIntervalSince(lastReport) > 0.05 {
                lastReport = Date()
                progress(min(1, Double(archive_filter_bytes(archive, -1)) / Double(archiveSize)))
            }
        }

        let isRaw = formatName == "raw"
        let filterName = filterDescription(archive)
        if formatName.lowercased().hasPrefix("zip"), let records = zipDirectory?.records {
            for index in entries.indices {
                guard let record = records[entries[index].path] else { continue }
                entries[index].compressedSize = record.compressedSize
                entries[index].crc32 = record.crc32
                entries[index].method = record.method
                entries[index].isEncrypted = entries[index].isEncrypted || record.isEncrypted
                if entries[index].size == nil { entries[index].size = record.uncompressedSize }
            }
        }

        return ArchiveInfo(
            url: url,
            formatName: prettyFormatName(formatName, filter: filterName),
            filterName: isRaw ? nil : filterName,
            archiveSize: archiveSize,
            entries: entries
        )
    }

    // MARK: Extraction

    /// Extracts the entries chosen by `plan` into `destination`, which must exist.
    /// Returns the top-level items written, in archive order.
    @discardableResult
    static func extract(
        url: URL,
        password: String?,
        plan: ExtractionPlan,
        destination: URL,
        progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) throws -> [URL] {
        let legacyNames = ZipCentralDirectory.read(url: url)?.hasLegacyNames ?? false
        let archive = try openForReading(url, password: password, legacyNames: legacyNames)
        defer { archive_read_free(archive) }

        guard let disk = archive_write_disk_new() else { throw ArchiveError.writeFailed("") }
        defer { archive_write_free(disk) }
        archive_write_disk_set_options(
            disk,
            ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_UNLINK
                | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT
        )

        let archiveSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let root = destination.path
        var topLevel: [String] = []
        var seenTopLevel = Set<String>()
        var bytesDone: Int64 = 0
        var lastReport = Date.distantPast
        var isRaw = false
        var entry: OpaquePointer?

        func report(_ name: String, force: Bool = false) {
            guard let progress, force || Date().timeIntervalSince(lastReport) > 0.05 else { return }
            lastReport = Date()
            let fraction: Double
            if plan.totalBytes > 0 {
                fraction = Double(bytesDone) / Double(plan.totalBytes)
            } else if archiveSize > 0 {
                fraction = Double(archive_filter_bytes(archive, -1)) / Double(archiveSize)
            } else {
                fraction = 0
            }
            progress(ExtractionProgress(fraction: min(1, fraction), currentItem: name))
        }

        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw LibArchive.readError(archive, hadPassword: password != nil) }
            guard let entry else { continue }
            if Task.isCancelled { throw ArchiveError.cancelled }

            if topLevel.isEmpty, let format = archive_format_name(archive), String(cString: format) == "raw" { isRaw = true }
            var path = entryPath(entry)
            if isRaw { path = url.deletingPathExtension().lastPathComponent }

            guard !path.isEmpty,
                  !(plan.skipMacMetadata && ArchivePath.isMacMetadata(path)),
                  let relative = plan.map(path).map(ArchivePath.normalize), !relative.isEmpty
            else {
                archive_read_data_skip(archive)
                continue
            }

            if let hardlink = archive_entry_hardlink(entry) {
                guard let target = plan.map(ArchivePath.normalize(ArchivePath.decode(hardlink))) else {
                    archive_read_data_skip(archive)
                    continue
                }
                archive_entry_copy_hardlink(entry, "\(root)/\(ArchivePath.normalize(target))")
            }

            if archive_entry_is_encrypted(entry) != 0, password == nil { throw ArchiveError.passwordRequired }

            let first = String(relative.prefix { $0 != "/" })
            if seenTopLevel.insert(first).inserted { topLevel.append(first) }

            archive_entry_copy_pathname(entry, "\(root)/\(relative)")
            let headerStatus = archive_write_header(disk, entry)
            if headerStatus < ARCHIVE_WARN {
                if headerStatus == ARCHIVE_FATAL { throw ArchiveError.writeFailed(LibArchive.errorMessage(disk)) }
                archive_read_data_skip(archive)
                continue
            }

            let name = ArchivePath.name(of: relative)
            if archive_entry_size_is_set(entry) == 0 || archive_entry_size(entry) > 0 || isRaw {
                var buffer: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                while true {
                    let readStatus = archive_read_data_block(archive, &buffer, &size, &offset)
                    if readStatus == ARCHIVE_EOF { break }
                    if readStatus < ARCHIVE_WARN { throw LibArchive.readError(archive, hadPassword: password != nil) }
                    if size > 0, archive_write_data_block(disk, buffer, size, offset) < 0 {
                        throw ArchiveError.writeFailed(LibArchive.errorMessage(disk))
                    }
                    bytesDone += Int64(size)
                    if Task.isCancelled { throw ArchiveError.cancelled }
                    report(name)
                }
            }
            if archive_write_finish_entry(disk) == ARCHIVE_FATAL {
                throw ArchiveError.writeFailed(LibArchive.errorMessage(disk))
            }
            report(name)
        }

        // Applies deferred directory permissions and modification times.
        archive_write_close(disk)
        report("", force: true)
        return topLevel.map { destination.appendingPathComponent($0) }
    }

    // MARK: Helpers

    static func openForReading(_ url: URL, password: String?, legacyNames: Bool) throws -> OpaquePointer {
        LibArchive.prepare()
        guard let archive = archive_read_new() else { throw ArchiveError.cannotOpen("") }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        archive_read_support_format_raw(archive)
        // Unflagged non-UTF-8 zip names: assume Turkish DOS (CP857), matching ArchivePath.decode.
        if legacyNames { archive_read_set_options(archive, "zip:hdrcharset=CP857") }
        if let password, !password.isEmpty { archive_read_add_passphrase(archive, password) }

        let status = url.withUnsafeFileSystemRepresentation { path in
            archive_read_open_filename(archive, path, blockSize)
        }
        if status != ARCHIVE_OK {
            let message = LibArchive.errorMessage(archive)
            archive_read_free(archive)
            if message.lowercased().contains("unrecognized archive format") { throw ArchiveError.notAnArchive }
            throw ArchiveError.cannotOpen(message)
        }
        return archive
    }

    static func entryPath(_ entry: OpaquePointer) -> String {
        guard let raw = archive_entry_pathname(entry) ?? archive_entry_pathname_utf8(entry) else { return "" }
        return ArchivePath.normalize(ArchivePath.decode(raw))
    }

    private static func makeEntry(_ entry: OpaquePointer) -> ArchiveEntry {
        let type = Int32(archive_entry_filetype(entry))
        let kind: ArchiveEntry.Kind = switch type {
        case AE_IFDIR: .directory
        case AE_IFLNK: .symlink
        default: .file
        }
        let rawPath = archive_entry_pathname(entry) ?? archive_entry_pathname_utf8(entry)
        let isDirectoryByName = rawPath.map { strlen($0) > 0 && $0[strlen($0) - 1] == CChar(UInt8(ascii: "/")) } ?? false

        return ArchiveEntry(
            path: entryPath(entry),
            kind: isDirectoryByName ? .directory : kind,
            size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            compressedSize: nil,
            modified: archive_entry_mtime_is_set(entry) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil,
            permissions: UInt16(archive_entry_perm(entry)),
            isEncrypted: archive_entry_is_encrypted(entry) != 0,
            crc32: nil,
            method: nil,
            linkTarget: archive_entry_symlink(entry).map(ArchivePath.decode)
        )
    }

    private static func filterDescription(_ archive: OpaquePointer) -> String? {
        let names = (0..<archive_filter_count(archive)).compactMap { index -> String? in
            guard let name = archive_filter_name(archive, index) else { return nil }
            let value = String(cString: name)
            return value == "none" ? nil : value.uppercased()
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private static func prettyFormatName(_ name: String, filter: String?) -> String {
        let lowered = name.lowercased()
        if lowered.hasPrefix("zip") { return "ZIP" }
        if lowered.hasPrefix("7-zip") { return "7-ZIP" }
        if lowered.hasPrefix("rar5") { return "RAR5" }
        if lowered.hasPrefix("rar") { return "RAR" }
        if ["tar", "pax", "ustar", "gnu", "posix"].contains(where: lowered.contains) { return "TAR" }
        if lowered.hasPrefix("iso") { return "ISO" }
        if lowered.hasPrefix("cpio") { return "CPIO" }
        if lowered == "raw" { return filter ?? String(localized: "Compressed file") }
        return name.uppercased()
    }
}
