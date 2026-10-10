import AppKit
import UniformTypeIdentifiers

struct HandledArchiveType: Identifiable, Hashable {
    let id: String
    let title: String
    let extensions: String

    var utType: UTType { UTType(id) ?? UTType(importedAs: id) }
}

/// Which app Finder uses for each archive type, and making Dürücü that app.
@MainActor
enum DefaultApps {
    static let types: [HandledArchiveType] = [
        HandledArchiveType(id: "public.zip-archive", title: "ZIP", extensions: ".zip"),
        HandledArchiveType(id: "org.7-zip.7-zip-archive", title: "7-Zip", extensions: ".7z"),
        HandledArchiveType(id: "com.rarlab.rar-archive", title: "RAR", extensions: ".rar"),
        HandledArchiveType(id: "public.tar-archive", title: "Tar", extensions: ".tar"),
        HandledArchiveType(id: "org.gnu.gnu-zip-tar-archive", title: "Tar + Gzip", extensions: ".tgz"),
        HandledArchiveType(id: "org.gnu.gnu-zip-archive", title: "Gzip", extensions: ".gz, .tar.gz"),
        HandledArchiveType(id: "org.tukaani.xz-archive", title: "XZ", extensions: ".xz, .tar.xz"),
        HandledArchiveType(id: "org.tukaani.tar-xz-archive", title: "Tar + XZ", extensions: ".txz"),
        HandledArchiveType(id: "public.bzip2-archive", title: "Bzip2", extensions: ".bz2"),
        HandledArchiveType(id: "public.tar-bzip2-archive", title: "Tar + Bzip2", extensions: ".tbz, .tar.bz2"),
    ]

    static var zip: HandledArchiveType { types[0] }

    static func handler(for type: HandledArchiveType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: type.utType)
    }

    static func handlerName(for type: HandledArchiveType) -> String {
        guard let url = handler(for: type) else { return String(localized: "None") }
        if isOurs(url) { return "Dürücü" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func isDefault(for type: HandledArchiveType) -> Bool {
        handler(for: type).map(isOurs) ?? false
    }

    static var isDefaultForAll: Bool { types.allSatisfy(isDefault) }

    /// Returns `false` when the user declined the system prompt or Launch Services refused.
    @discardableResult
    static func makeDefault(_ selection: [HandledArchiveType] = types) async -> Bool {
        var succeeded = true
        for type in selection where !isDefault(for: type) {
            // The completion-handler form is used on purpose: it reports when Launch Services
            // has actually stored the change (and after any system confirmation).
            let error: Error? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type.utType) { error in
                    continuation.resume(returning: error)
                }
            }
            if error != nil { succeeded = false }
        }
        return succeeded
    }

    private static let claimedKey = "claimedDefaultHandlers"

    /// Dürücü exists to replace Archive Utility's extract-on-double-click, so it claims the
    /// archive types once, on its first launch from a real install.
    static func claimOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: claimedKey), Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: claimedKey)
        Task { await makeDefault() }
    }

    private static func isOurs(_ url: URL) -> Bool {
        Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
