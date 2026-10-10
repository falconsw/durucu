import AppKit
import Observation

/// Extracts an archive straight away, without opening the browser window.
/// Used by the "extract immediately" preference and the Finder service.
@MainActor
@Observable
final class QuickExtractModel {
    enum Phase: Equatable {
        case working
        case needsPassword(isRetry: Bool)
        case failed(String)
        case done([URL])
    }

    let url: URL
    private let destinationOverride: URL?
    private(set) var phase: Phase = .working
    private(set) var fraction: Double = 0
    private(set) var currentItem = ""
    var onFinish: (@MainActor () -> Void)?
    weak var window: NSWindow?

    private var password: String?
    fileprivate var task: Task<Void, Never>?

    init(url: URL, destination: URL? = nil) {
        self.url = url
        destinationOverride = destination
    }

    func start() {
        task?.cancel()
        phase = .working
        fraction = 0
        task = Task { [weak self] in
            guard let self else { return }
            var destination = self.destinationOverride ?? ExtractionService.defaultDestination(for: self.url)
            if destination == nil {
                destination = await ExtractionService.chooseDestination(for: self.url, window: nil)
            }
            guard let destination else {
                self.onFinish?()
                return
            }

            let request = ExtractionService.Request(
                archive: self.url,
                password: self.password,
                roots: nil,
                destination: destination,
                smartFolder: Pref.bool(Pref.smartFolder),
                totalBytes: 0,
                skipMacMetadata: !Pref.bool(Pref.showMacMetadata)
            )
            do {
                let outputs = try await ExtractionService.run(request) { [weak self] progress in
                    self?.fraction = progress.fraction
                    self?.currentItem = progress.currentItem
                }
                self.complete(outputs)
            } catch ArchiveError.cancelled {
                self.onFinish?()
            } catch ArchiveError.passwordRequired {
                self.phase = .needsPassword(isRetry: false)
            } catch ArchiveError.wrongPassword {
                self.phase = .needsPassword(isRetry: true)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func submit(password value: String) {
        password = value
        start()
    }

    func cancel() {
        if phase == .working, let task {
            task.cancel()
        } else {
            onFinish?()
        }
    }

    private func complete(_ outputs: [URL]) {
        phase = .done(outputs)
        if Pref.bool(Pref.revealAfterExtract), !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
        if Pref.bool(Pref.trashAfterQuickExtract), !outputs.isEmpty {
            NSWorkspace.shared.recycle([url])
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.onFinish?()
        }
    }
}

extension QuickExtractModel: BackgroundWork {
    var isBusy: Bool { phase == .working }
    var busyTitle: String { "“\(url.lastPathComponent)” çıkartılıyor" }

    func cancelAndWait() async {
        task?.cancel()
        await task?.value
    }
}
