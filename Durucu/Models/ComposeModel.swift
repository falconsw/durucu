import AppKit
import Observation

/// State of the "new archive" window.
@MainActor
@Observable
final class ComposeModel {
    enum Phase {
        case editing
        case working
        case done(Outcome)
        case failed(String)
    }

    struct Outcome {
        var output: URL
        var originalBytes: Int64
        var archiveBytes: Int64
        var duration: TimeInterval
    }

    struct Source: Identifiable, Hashable {
        var url: URL
        var id: URL { url }
        var bytes: Int64?
        var isDirectory: Bool
    }

    private(set) var sources: [Source] = []
    var name = String(localized: "Archive")
    private var nameWasEdited = false
    var destination: URL
    var format = Pref.defaultFormatValue
    var level = Pref.defaultLevelValue
    var usesPassword = false
    var password = ""
    var passwordConfirmation = ""
    var excludesMacMetadata = Pref.bool(Pref.excludeMacMetadata) {
        didSet { rescan() }
    }

    private(set) var totalBytes: Int64 = 0
    private(set) var fileCount = 0
    private(set) var isScanning = false
    private(set) var phase: Phase = .editing
    private(set) var progress = CompressionProgress(fraction: 0, currentItem: "", bytesDone: 0)
    private(set) var startedAt = Date()

    private var scanTask: Task<Void, Never>?
    fileprivate var workTask: Task<Void, Never>?

    init(sources urls: [URL]) {
        destination = urls.first?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        add(urls)
    }

    var outputFileName: String { "\(trimmedName).\(format.fileExtension)" }
    private var trimmedName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        return value.isEmpty ? String(localized: "Archive") : value
    }

    var passwordProblem: String? {
        guard usesPassword, format.supportsPassword else { return nil }
        if password.isEmpty { return String(localized: "Enter a password.") }
        if password != passwordConfirmation { return String(localized: "The passwords don't match.") }
        return nil
    }

    var canStart: Bool { !sources.isEmpty && passwordProblem == nil && !isScanning }

    var bytesPerSecond: Double {
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 0.5 ? Double(progress.bytesDone) / elapsed : 0
    }

    var remainingSeconds: Double? {
        let speed = bytesPerSecond
        guard speed > 0, progress.fraction > 0.02 else { return nil }
        return Double(totalBytes - progress.bytesDone) / speed
    }

    // MARK: Sources

    func add(_ urls: [URL]) {
        let existing = Set(sources.map(\.url.standardizedFileURL))
        let fresh = urls.filter { !existing.contains($0.standardizedFileURL) && FileManager.default.fileExists(atPath: $0.path) }
        guard !fresh.isEmpty else { return }
        sources += fresh.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Source(url: url, bytes: nil, isDirectory: isDirectory)
        }
        suggestName()
        rescan()
    }

    func remove(_ ids: Set<URL>) {
        sources.removeAll { ids.contains($0.id) }
        suggestName()
        rescan()
    }

    func renameByUser(_ value: String) {
        name = value
        nameWasEdited = true
    }

    private func suggestName() {
        guard !nameWasEdited else { return }
        if sources.count == 1, let only = sources.first {
            name = only.url.lastPathComponent
        } else if sources.count > 1 {
            let parent = sources[0].url.deletingLastPathComponent()
            name = sources.allSatisfy({ $0.url.deletingLastPathComponent() == parent }) ? parent.lastPathComponent : String(localized: "Archive")
        } else {
            name = String(localized: "Archive")
        }
    }

    private func rescan() {
        scanTask?.cancel()
        let urls = sources.map(\.url)
        let exclude = excludesMacMetadata
        isScanning = true
        scanTask = Task { [weak self] in
            let result = await Self.measure(urls, exclude: exclude)
            guard let self, !Task.isCancelled else { return }
            for index in self.sources.indices {
                self.sources[index].bytes = result.perSource[self.sources[index].url]
            }
            self.totalBytes = result.total
            self.fileCount = result.files
            self.isScanning = false
        }
    }

    private struct Measurement: Sendable {
        var perSource: [URL: Int64]
        var total: Int64
        var files: Int
    }

    @concurrent
    private static func measure(_ urls: [URL], exclude: Bool) async -> Measurement {
        var perSource: [URL: Int64] = [:]
        var total: Int64 = 0
        var files = 0
        for url in urls {
            let items = ArchiveWriter.collect([url], excludeMacMetadata: exclude)
            let bytes = items.reduce(Int64(0)) { $0 + $1.size }
            perSource[url] = bytes
            total += bytes
            files += items.filter { $0.kind == .file }.count
        }
        return Measurement(perSource: perSource, total: total, files: files)
    }

    // MARK: Destination

    func chooseDestination(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = destination
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = panel.url { self?.destination = url }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    // MARK: Work

    func start() {
        guard canStart else { return }
        let urls = sources.map(\.url)
        let exclude = excludesMacMetadata
        let format = format
        let level = level
        let password = usesPassword && format.supportsPassword ? password : nil
        let final = FileNaming.uniqueURL(in: destination, name: outputFileName, isDirectory: false)
        let partial = destination.appendingPathComponent(".\(final.lastPathComponent).durucu-part")

        phase = .working
        progress = CompressionProgress(fraction: 0, currentItem: "", bytesDone: 0)
        startedAt = Date()
        let began = startedAt

        workTask = Task { [weak self] in
            do {
                let outcome = try await Self.compress(
                    urls: urls, exclude: exclude, partial: partial, final: final,
                    format: format, level: level, password: password
                ) { value in
                    Task { @MainActor in self?.progress = value }
                }
                guard let self else { return }
                self.phase = .done(Outcome(
                    output: final,
                    originalBytes: outcome.original,
                    archiveBytes: outcome.archive,
                    duration: Date().timeIntervalSince(began)
                ))
            } catch ArchiveError.cancelled {
                self?.phase = .editing
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    @concurrent
    private static func compress(
        urls: [URL], exclude: Bool, partial: URL, final: URL, format: OutputFormat, level: CompressionLevel,
        password: String?, progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> (original: Int64, archive: Int64) {
        let items = ArchiveWriter.collect(urls, excludeMacMetadata: exclude)
        do {
            try ArchiveWriter.create(items: items, output: partial, format: format, level: level, password: password, progress: progress)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let size = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (items.reduce(0) { $0 + $1.size }, Int64(size))
    }

    func cancel() {
        workTask?.cancel()
    }

    func backToEditing() {
        phase = .editing
    }
}

extension ComposeModel: BackgroundWork {
    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    var busyTitle: String { String(localized: "Creating “\(outputFileName)”") }

    func cancelAndWait() async {
        workTask?.cancel()
        await workTask?.value
    }
}
