import Foundation
import CLibArchive

/// One entry exactly as the archive lists it.
struct ArchiveEntry: Sendable, Hashable {
    enum Kind: Sendable, Hashable { case file, directory, symlink }

    /// Normalized path: no leading `/` or `./`, no trailing `/`, no `..` components.
    var path: String
    var kind: Kind
    var size: Int64?
    var compressedSize: Int64?
    var modified: Date?
    var permissions: UInt16
    var isEncrypted: Bool
    var crc32: UInt32?
    var method: String?
    var linkTarget: String?
}

struct ArchiveInfo: Sendable {
    var url: URL
    var formatName: String
    var filterName: String?
    var archiveSize: Int64
    var entries: [ArchiveEntry]

    var hasEncryptedEntries: Bool { entries.contains { $0.isEncrypted } }

    /// "ZIP", "TAR · GZIP", "7-ZIP" …
    var displayFormat: String {
        if let filterName { return "\(formatName) · \(filterName)" }
        return formatName
    }
}

enum ArchiveError: LocalizedError, Equatable {
    case cannotOpen(String)
    case notAnArchive
    case passwordRequired
    case wrongPassword
    case unsupportedEncryption
    case cancelled
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let detail): String(localized: "The archive couldn't be opened. \(detail)")
        case .notAnArchive: String(localized: "This file isn't in an archive format Dürücü recognizes.")
        case .passwordRequired: String(localized: "This archive is password protected.")
        case .wrongPassword: String(localized: "The password is incorrect.")
        case .unsupportedEncryption: String(localized: "This archive's encryption isn't supported (encrypted 7z/RAR).")
        case .cancelled: String(localized: "The operation was cancelled.")
        case .readFailed(let detail): String(localized: "Something went wrong while reading the archive. \(detail)")
        case .writeFailed(let detail): String(localized: "Couldn't write. \(detail)")
        }
    }
}

enum LibArchive {
    /// libarchive converts entry names through the C locale. Running in a UTF-8
    /// locale makes multibyte pathnames round-trip as UTF-8 bytes.
    private static let localeReady: Bool = {
        setlocale(LC_CTYPE, "UTF-8") != nil || setlocale(LC_CTYPE, "en_US.UTF-8") != nil
    }()

    static func prepare() { _ = localeReady }

    static func errorMessage(_ archive: OpaquePointer) -> String {
        guard let cString = archive_error_string(archive) else { return "" }
        return String(cString: cString)
    }

    /// Maps libarchive's free-form error text onto the cases the UI handles specially.
    static func readError(_ archive: OpaquePointer, hadPassword: Bool) -> ArchiveError {
        let message = errorMessage(archive)
        let lowered = message.lowercased()
        if lowered.contains("incorrect passphrase") {
            return hadPassword ? .wrongPassword : .passwordRequired
        }
        if lowered.contains("passphrase") { return hadPassword ? .wrongPassword : .passwordRequired }
        if lowered.contains("encrypt"), lowered.contains("support") { return .unsupportedEncryption }
        return .readFailed(message)
    }
}

enum ArchivePath {
    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    static func decode(_ cString: UnsafePointer<CChar>) -> String {
        let length = strlen(cString)
        return cString.withMemoryRebound(to: UInt8.self, capacity: length) {
            decode(bytes: UnsafeBufferPointer(start: $0, count: length))
        }
    }

    /// Names are UTF-8 in modern archives. Zips made by older Windows tools store
    /// names in the OEM code page, which for Turkish systems is CP857.
    static func decode<Bytes: Collection<UInt8>>(bytes: Bytes) -> String {
        if let utf8 = String(validating: bytes, as: UTF8.self) { return utf8 }
        let dosTurkish = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosTurkish.rawValue))
        if let legacy = String(data: Data(bytes), encoding: String.Encoding(rawValue: dosTurkish)) { return legacy }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Finder's `__MACOSX/` AppleDouble companions and `.DS_Store` files.
    static func isMacMetadata(_ path: String) -> Bool {
        if path == "__MACOSX" || path.hasPrefix("__MACOSX/") { return true }
        let name = name(of: path)
        return name == ".DS_Store" || name.hasPrefix("._")
    }
}
