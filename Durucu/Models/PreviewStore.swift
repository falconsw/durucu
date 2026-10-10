import Foundation

/// Extracts single entries on demand for Quick Look, opening and dragging out.
/// Each archive window gets its own folder under Caches, removed when it closes.
@MainActor
final class PreviewStore {
    static var rootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Durucu", isDirectory: true)
            .appendingPathComponent("Previews", isDirectory: true)
    }

    private let archive: URL
    private let directory: URL
    private var cache: [String: URL] = [:]
    private var inflight: [String: Task<URL, Error>] = [:]

    init(archive: URL) {
        self.archive = archive
        directory = Self.rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func cachedFile(for node: ArchiveNode) -> URL? {
        guard let url = cache[node.path], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func file(for node: ArchiveNode, password: String?) async throws -> URL {
        if let cached = cachedFile(for: node) { return cached }
        if let running = inflight[node.path] { return try await running.value }

        let folder = directory.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        let request = ExtractionService.Request(
            archive: archive,
            password: password,
            roots: [ExtractionService.Root(path: node.path, name: node.name)],
            destination: folder,
            smartFolder: false,
            totalBytes: node.size,
            skipMacMetadata: true
        )
        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let outputs = try await ExtractionService.run(request) { _ in }
            guard let output = outputs.first else { throw ArchiveError.readFailed("“\(node.name)” bulunamadı.") }
            return output
        }
        inflight[node.path] = task
        defer { inflight[node.path] = nil }
        let url = try await task.value
        cache[node.path] = url
        return url
    }

    /// Drops every extracted copy, e.g. after the archive itself changed.
    func reset() {
        purge()
        cache = [:]
        inflight = [:]
    }

    func purge() {
        inflight.values.forEach { $0.cancel() }
        try? FileManager.default.removeItem(at: directory)
    }

    static func purgeAll() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
