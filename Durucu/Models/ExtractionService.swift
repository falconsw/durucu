import AppKit

/// Extracts into a hidden staging folder next to the destination, then moves the
/// results into place. Nothing half-written is ever left at the final location
/// and existing files are never overwritten.
enum ExtractionService {
    struct Root: Sendable {
        var path: String
        var name: String
    }

    struct Request: Sendable {
        var archive: URL
        var password: String?
        /// `nil` extracts everything into a folder named after the archive.
        var roots: [Root]?
        var destination: URL
        var smartFolder: Bool
        var totalBytes: Int64
        var skipMacMetadata: Bool
    }

    @MainActor
    static func run(_ request: Request, progress: @escaping @MainActor @Sendable (ExtractionProgress) -> Void) async throws -> [URL] {
        try await perform(request) { value in
            Task { @MainActor in progress(value) }
        }
    }

    @concurrent
    private static func perform(_ request: Request, progress: @escaping @Sendable (ExtractionProgress) -> Void) async throws -> [URL] {
        let fileManager = FileManager.default
        let staging = request.destination.appendingPathComponent(".Dürücü-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw ArchiveError.writeFailed("“\(request.destination.lastPathComponent)” klasörüne yazılamıyor.")
        }

        do {
            let topLevel = try ArchiveReader.extract(
                url: request.archive,
                password: request.password,
                plan: plan(for: request),
                destination: staging,
                progress: progress
            )
            let results = try place(topLevel, from: staging, request: request)
            try? fileManager.removeItem(at: staging)
            return results
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static func plan(for request: Request) -> ExtractionPlan {
        guard let roots = request.roots, !roots.contains(where: { $0.path.isEmpty }) else {
            return .everything(totalBytes: request.totalBytes, skipMacMetadata: request.skipMacMetadata)
        }
        let lookup = Dictionary(roots.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ExtractionPlan(
            map: { path in
                var candidate = Substring(path)
                while true {
                    if let name = lookup[String(candidate)] {
                        return name + path.dropFirst(candidate.count)
                    }
                    guard let slash = candidate.lastIndex(of: "/") else { return nil }
                    candidate = candidate[..<slash]
                }
            },
            totalBytes: request.totalBytes,
            skipMacMetadata: request.skipMacMetadata
        )
    }

    private static func place(_ topLevel: [URL], from staging: URL, request: Request) throws -> [URL] {
        let fileManager = FileManager.default
        let destination = request.destination
        let items = topLevel.filter { fileManager.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { return [] }

        func move(_ item: URL) throws -> URL {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let target = FileNaming.uniqueURL(in: destination, name: item.lastPathComponent, isDirectory: isDirectory)
            try fileManager.moveItem(at: item, to: target)
            return target
        }

        // Selected items land directly in the destination.
        if request.roots != nil { return try items.map(move) }

        // A single top-level item needs no wrapper folder.
        if request.smartFolder, items.count == 1 { return [try move(items[0])] }

        let wrapper = FileNaming.uniqueURL(in: destination, name: FileNaming.baseName(of: request.archive), isDirectory: true)
        try fileManager.moveItem(at: staging, to: wrapper)
        return [wrapper]
    }

    /// Where "extract" puts things by default. `nil` means the user has to choose.
    @MainActor
    static func defaultDestination(for archive: URL) -> URL? {
        switch Pref.extractDestinationValue {
        case .beside:
            let folder = archive.deletingLastPathComponent()
            return FileManager.default.isWritableFile(atPath: folder.path) ? folder : nil
        case .custom:
            return Pref.customDestinationURL
        case .ask:
            return nil
        }
    }

    @MainActor
    static func chooseDestination(for archive: URL, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Buraya Çıkart"
        panel.message = "“\(archive.lastPathComponent)” nereye çıkartılsın?"
        panel.directoryURL = archive.deletingLastPathComponent()
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}
