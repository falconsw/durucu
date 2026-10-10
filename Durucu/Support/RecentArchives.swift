import AppKit
import Observation

@MainActor
@Observable
final class RecentArchives {
    static let shared = RecentArchives()

    private static let key = "recentArchives"
    private static let limit = 12

    private(set) var urls: [URL]

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func note(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(Self.limit))
        save()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func prune() {
        urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        save()
    }

    func clear() {
        urls = []
        save()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.key)
    }
}
