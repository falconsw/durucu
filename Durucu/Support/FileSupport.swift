import AppKit
import UniformTypeIdentifiers

enum FileNaming {
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.lzma", "tar.z"]

    /// "Project.tar.gz" → "Project", "Photos.zip" → "Photos".
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        if let compound = compoundExtensions.first(where: { lowered.hasSuffix("." + $0) }) {
            return String(name.dropLast(compound.count + 1))
        }
        let stripped = url.deletingPathExtension().lastPathComponent
        return stripped.isEmpty ? name : stripped
    }

    /// Finder-style "name 2.ext" when `name.ext` already exists in `directory`.
    static func uniqueURL(in directory: URL, name: String, isDirectory: Bool) -> URL {
        let unique = uniqueName(name, isDirectory: isDirectory) { candidate in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(unique, isDirectory: isDirectory)
    }

    /// "name", or the first free "name 2", "name 3"… with the extension kept at the end.
    static func uniqueName(_ name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let stem: String
        let suffix: String
        if isDirectory {
            stem = name
            suffix = ""
        } else if let compound = compoundExtensions.first(where: { name.lowercased().hasSuffix("." + $0) }) {
            stem = String(name.dropLast(compound.count + 1))
            suffix = String(name.suffix(compound.count + 1))
        } else {
            let ext = (name as NSString).pathExtension
            stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            suffix = ext.isEmpty ? "" : "." + ext
        }
        var counter = 2
        while isTaken("\(stem) \(counter)\(suffix)") { counter += 1 }
        return "\(stem) \(counter)\(suffix)"
    }

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma", "tlz", "cpio", "xar", "cab", "lha", "lzh", "z",
    ]

    static func looksLikeArchive(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if archiveExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .archive) { return true }
        return false
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(localized: "under a second") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: seconds) ?? String(localized: "\(Int(seconds)) s")
    }

    static func permissions(_ mode: UInt16) -> String {
        let symbols: [Character] = ["r", "w", "x"]
        return (0..<9).map { bit in
            mode & (1 << (8 - bit)) != 0 ? String(symbols[bit % 3]) : "-"
        }.joined()
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static var folder: NSImage { icon(forType: .folder, key: "/folder") }

    static func icon(forName name: String, isDirectory: Bool, isSymlink: Bool = false) -> NSImage {
        if isDirectory {
            let ext = (name as NSString).pathExtension.lowercased()
            // Bundles such as .app keep their own icon even inside an archive.
            if let type = UTType(filenameExtension: ext), type.conforms(to: .package) {
                return icon(forType: type, key: "pkg." + ext)
            }
            return folder
        }
        if isSymlink { return icon(forType: .symbolicLink, key: "/symlink") }
        let ext = (name as NSString).pathExtension.lowercased()
        return icon(forType: UTType(filenameExtension: ext) ?? .data, key: ext)
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func icon(forType type: UTType, key: String) -> NSImage {
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
