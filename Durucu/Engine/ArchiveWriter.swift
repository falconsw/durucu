import Foundation
import CLibArchive

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, sevenZip, tarGz, tarXz, tarBz2, tar

    /// Formats offered when making a new archive. The rest exist so existing archives can be rewritten.
    static let creatable: [OutputFormat] = [.zip, .sevenZip, .tarGz, .tarXz]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7Z"
        case .tarGz: "TAR.GZ"
        case .tarXz: "TAR.XZ"
        case .tarBz2: "TAR.BZ2"
        case .tar: "TAR"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tarGz: "tar.gz"
        case .tarXz: "tar.xz"
        case .tarBz2: "tar.bz2"
        case .tar: "tar"
        }
    }

    var summary: String {
        switch self {
        case .zip: String(localized: "Opens everywhere: Windows, macOS, phones.")
        case .sevenZip: String(localized: "Usually the smallest. Opens in 7-Zip, Keka and Dürücü.")
        case .tarGz: String(localized: "The Unix standard. Keeps permissions.")
        case .tarXz: String(localized: "A tighter TAR. Slower but smaller.")
        case .tarBz2: String(localized: "An older but common TAR compression.")
        case .tar: String(localized: "Uncompressed TAR.")
        }
    }

    var supportsPassword: Bool { self == .zip }

    /// The format to write when an existing archive is modified, or `nil` when libarchive can't write it (RAR, ISO…).
    init?(rewriting info: ArchiveInfo) {
        switch (info.formatName, info.filterName) {
        case ("ZIP", nil): self = .zip
        case ("7-ZIP", nil): self = .sevenZip
        case ("TAR", nil): self = .tar
        case ("TAR", "GZIP"): self = .tarGz
        case ("TAR", "XZ"): self = .tarXz
        case ("TAR", "BZIP2"): self = .tarBz2
        default: return nil
        }
    }
}

enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case store, fast, balanced, best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .store: String(localized: "None")
        case .fast: String(localized: "Fast")
        case .balanced: String(localized: "Balanced")
        case .best: String(localized: "Best")
        }
    }

    var numeric: Int {
        switch self {
        case .store: 0
        case .fast: 1
        case .balanced: 6
        case .best: 9
        }
    }
}

/// A file system item resolved for writing into an archive.
struct SourceItem: Sendable {
    var url: URL
    var archivePath: String
    var kind: ArchiveEntry.Kind
    var size: Int64
    var modifiedSeconds: Int
    var modifiedNanoseconds: Int
    var permissions: mode_t
    var linkTarget: String?
}

struct CompressionProgress: Sendable {
    var fraction: Double
    var currentItem: String
    var bytesDone: Int64
}

/// One archive being written to disk. Used from a single task at a time.
final class ArchiveOutput {
    private let archive: OpaquePointer
    private var isClosed = false

    init(url: URL, format: OutputFormat, level: CompressionLevel, password: String?) throws {
        LibArchive.prepare()
        guard let archive = archive_write_new() else { throw ArchiveError.writeFailed("") }
        self.archive = archive

        var options: [String] = []
        switch format {
        case .zip:
            archive_write_set_format_zip(archive)
            options.append("zip:hdrcharset=UTF-8")
            if level == .store {
                options.append("zip:compression=store")
            } else {
                options += ["zip:compression=deflate", "zip:compression-level=\(level.numeric)"]
            }
            if let password, !password.isEmpty {
                options.append("zip:encryption=aes256")
                archive_write_set_passphrase(archive, password)
            }
        case .sevenZip:
            archive_write_set_format_7zip(archive)
            if level == .store {
                options.append("7zip:compression=copy")
            } else {
                options += ["7zip:compression=lzma2", "7zip:compression-level=\(level.numeric)"]
            }
        case .tarGz:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_gzip(archive)
            options.append("gzip:compression-level=\(max(1, level.numeric))")
        case .tarXz:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_xz(archive)
            options += ["xz:compression-level=\(level.numeric)", "xz:threads=0"]
        case .tarBz2:
            archive_write_set_format_pax_restricted(archive)
            archive_write_add_filter_bzip2(archive)
            options.append("bzip2:compression-level=\(max(1, level.numeric))")
        case .tar:
            archive_write_set_format_pax_restricted(archive)
        }
        archive_write_set_bytes_in_last_block(archive, 1)
        if archive_write_set_options(archive, options.joined(separator: ",")) < ARCHIVE_WARN {
            throw ArchiveError.writeFailed(LibArchive.errorMessage(archive))
        }
        let opened = url.withUnsafeFileSystemRepresentation { archive_write_open_filename(archive, $0) }
        guard opened == ARCHIVE_OK else { throw ArchiveError.writeFailed(LibArchive.errorMessage(archive)) }
    }

    deinit {
        archive_write_free(archive)
    }

    /// Starts an entry. File data follows through `write(_:count:)`.
    func begin(
        path: String,
        kind: ArchiveEntry.Kind,
        size: Int64?,
        permissions: mode_t,
        modified: (seconds: Int, nanoseconds: Int),
        linkTarget: String? = nil,
        hardlink: String? = nil
    ) throws {
        guard let entry = archive_entry_new() else { throw ArchiveError.writeFailed("") }
        defer { archive_entry_free(entry) }

        // Windows and most tools expect precomposed (NFC) names.
        let name = path.precomposedStringWithCanonicalMapping
        archive_entry_copy_pathname(entry, kind == .directory ? name + "/" : name)
        archive_entry_set_perm(entry, permissions)
        archive_entry_set_mtime(entry, modified.seconds, modified.nanoseconds)
        switch kind {
        case .directory:
            archive_entry_set_filetype(entry, UInt32(AE_IFDIR))
            archive_entry_set_size(entry, 0)
        case .symlink:
            archive_entry_set_filetype(entry, UInt32(AE_IFLNK))
            archive_entry_set_size(entry, 0)
            archive_entry_copy_symlink(entry, linkTarget ?? "")
        case .file:
            archive_entry_set_filetype(entry, UInt32(AE_IFREG))
            if let size { archive_entry_set_size(entry, size) }
        }
        if let hardlink {
            archive_entry_copy_hardlink(entry, hardlink.precomposedStringWithCanonicalMapping)
            archive_entry_set_size(entry, 0)
        }
        if archive_write_header(archive, entry) < ARCHIVE_WARN {
            throw ArchiveError.writeFailed(LibArchive.errorMessage(archive))
        }
    }

    func write(_ bytes: UnsafeRawPointer, count: Int) throws {
        if archive_write_data(archive, bytes, count) < 0 {
            throw ArchiveError.writeFailed(LibArchive.errorMessage(archive))
        }
    }

    /// Writes the central directory / trailer. The archive is unusable until this succeeds.
    func finish() throws {
        guard !isClosed else { return }
        isClosed = true
        if archive_write_close(archive) < ARCHIVE_WARN {
            throw ArchiveError.writeFailed(LibArchive.errorMessage(archive))
        }
    }
}

enum ArchiveWriter {
    private static let excludedNames: Set<String> = [".DS_Store", "__MACOSX", ".Spotlight-V100", ".fseventsd", ".Trashes", "Icon\r"]
    static let bufferSize = 1 << 20

    static func isExcluded(_ name: String) -> Bool {
        excludedNames.contains(name) || name.hasPrefix("._")
    }

    /// Walks `sources` without following symbolic links. Each source lands at
    /// `prefix/<name>`, where the name is its own unless `names` overrides it.
    static func collect(
        _ sources: [URL],
        under prefix: String = "",
        names: [URL: String] = [:],
        excludeMacMetadata: Bool
    ) -> [SourceItem] {
        var items: [SourceItem] = []
        for source in sources {
            let name = names[source] ?? source.lastPathComponent
            let topPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard let top = makeItem(source, archivePath: topPath) else { continue }
            items.append(top)
            guard top.kind == .directory else { continue }

            let baseDepth = source.standardizedFileURL.pathComponents.count
            let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil, options: [])
            while let url = enumerator?.nextObject() as? URL {
                if excludeMacMetadata, isExcluded(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                let relative = url.standardizedFileURL.pathComponents.dropFirst(baseDepth).joined(separator: "/")
                if let item = makeItem(url, archivePath: "\(topPath)/\(relative)") {
                    items.append(item)
                }
            }
        }
        return items
    }

    static func create(
        items: [SourceItem],
        output url: URL,
        format: OutputFormat,
        level: CompressionLevel,
        password: String?,
        progress: (@Sendable (CompressionProgress) -> Void)? = nil
    ) throws {
        let output = try ArchiveOutput(url: url, format: format, level: level, password: password)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var meter = ProgressMeter(total: items.reduce(0) { $0 + ($1.kind == .file ? $1.size : 0) }, report: progress)
        for item in items {
            try write(item, to: output, buffer: buffer, meter: &meter)
        }
        try output.finish()
        meter.finish()
    }

    /// Copies one file system item into `output`, reading file data in 1 MB chunks.
    static func write(_ item: SourceItem, to output: ArchiveOutput, buffer: UnsafeMutableRawPointer, meter: inout ProgressMeter) throws {
        if Task.isCancelled { throw ArchiveError.cancelled }
        try output.begin(
            path: item.archivePath,
            kind: item.kind,
            size: item.size,
            permissions: item.permissions,
            modified: (item.modifiedSeconds, item.modifiedNanoseconds),
            linkTarget: item.linkTarget
        )
        guard item.kind == .file, item.size > 0 else { return }

        let descriptor = open(item.url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ArchiveError.writeFailed(String(localized: "Couldn't read “\(item.url.lastPathComponent)”.")) }
        defer { close(descriptor) }
        var remaining = item.size
        while remaining > 0 {
            let count = read(descriptor, buffer, min(bufferSize, Int(remaining)))
            if count < 0 { throw ArchiveError.writeFailed(String(localized: "Couldn't read “\(item.url.lastPathComponent)”.")) }
            if count == 0 { break }
            try output.write(buffer, count: count)
            remaining -= Int64(count)
            meter.advance(Int64(count), item: item.url.lastPathComponent)
            if Task.isCancelled { throw ArchiveError.cancelled }
        }
    }

    private static func makeItem(_ url: URL, archivePath: String) -> SourceItem? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let kind: ArchiveEntry.Kind
        var linkTarget: String?
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK:
            kind = .symlink
            linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        case S_IFREG: kind = .file
        default: return nil
        }
        return SourceItem(
            url: url,
            archivePath: archivePath,
            kind: kind,
            size: kind == .file ? Int64(info.st_size) : 0,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            permissions: info.st_mode & 0o7777,
            linkTarget: linkTarget
        )
    }
}

/// Throttled byte-count progress shared by archive creation and rewriting.
struct ProgressMeter {
    let total: Int64
    let report: (@Sendable (CompressionProgress) -> Void)?
    private(set) var done: Int64 = 0
    private var lastReport = Date.distantPast

    init(total: Int64, report: (@Sendable (CompressionProgress) -> Void)?) {
        self.total = max(1, total)
        self.report = report
    }

    mutating func advance(_ bytes: Int64, item: String) {
        done += bytes
        guard let report, Date().timeIntervalSince(lastReport) > 0.05 else { return }
        lastReport = Date()
        report(CompressionProgress(fraction: min(1, Double(done) / Double(total)), currentItem: item, bytesDone: done))
    }

    func finish() {
        report?(CompressionProgress(fraction: 1, currentItem: "", bytesDone: done))
    }
}
