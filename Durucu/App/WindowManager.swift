import AppKit
import Quartz
import SwiftUI

/// Owns every window. AppKit-managed windows let Finder "open document" events,
/// Services and the Dock all reach the same code paths.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var home: NSWindow?
    private var archives: [URL: (window: NSWindow, model: ArchiveModel)] = [:]
    private var others: Set<NSWindow> = []
    private var workers: [ObjectIdentifier: any BackgroundWork] = [:]

    /// Models with a job still running, for the quit confirmation.
    var busyWorkers: [any BackgroundWork] { workers.values.filter(\.isBusy) }

    var hasOpenWindows: Bool {
        home?.isVisible == true || !archives.isEmpty || !others.isEmpty
    }

    // MARK: Routing

    /// Archives open in a window; anything else goes into a new archive. Archives double-clicked
    /// in Finder follow the "open behavior" preference and may be extracted right away instead.
    func open(_ urls: [URL], fromFinder: Bool = false) {
        let archivesToOpen = urls.filter(FileNaming.looksLikeArchive)
        let others = urls.filter { !FileNaming.looksLikeArchive($0) }
        for url in archivesToOpen {
            if fromFinder, Pref.openBehaviorValue == .extract {
                quickExtract(url)
            } else {
                openArchive(url)
            }
        }
        if !others.isEmpty { showCompose(with: others) }
    }

    func openArchive(_ url: URL) {
        let key = url.standardizedFileURL
        if let existing = archives[key] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let model = ArchiveModel(url: url)
        let window = ArchiveWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1220, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.model = model
        window.representedURL = url
        window.title = url.lastPathComponent
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "archive"
        configure(window, content: ArchiveWindowView(model: model), size: NSSize(width: 1220, height: 720))
        window.setFrameAutosaveName("ArchiveWindow")
        model.window = window
        archives[key] = (window, model)
        workers[ObjectIdentifier(window)] = model
        cascade(window)
        window.makeKeyAndOrderFront(nil)
        model.load()
        home?.close()
    }

    func showHome() {
        if let home {
            home.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Dürücü"
        configure(window, content: HomeView(), size: NSSize(width: 860, height: 600))
        window.center()
        home = window
        window.makeKeyAndOrderFront(nil)
    }

    func showCompose(with urls: [URL]) {
        let model = ComposeModel(sources: urls)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Yeni Arşiv"
        configure(window, content: ComposeView(model: model, close: { [weak window] in window?.close() }),
                  size: NSSize(width: 640, height: 720))
        cascade(window)
        others.insert(window)
        workers[ObjectIdentifier(window)] = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func quickExtract(_ url: URL, destination: URL? = nil) {
        let model = QuickExtractModel(url: url, destination: destination)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.title = url.lastPathComponent
        model.window = window
        model.onFinish = { [weak window] in window?.close() }
        configure(window, content: QuickExtractView(model: model), size: NSSize(width: 420, height: 170))
        cascade(window)
        others.insert(window)
        workers[ObjectIdentifier(window)] = model
        window.makeKeyAndOrderFront(nil)
        model.start()
    }

    // MARK: Panels

    func chooseArchivesToOpen() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Aç"
        panel.message = "Açılacak arşivi seç"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Seç"
        panel.message = "Arşive eklenecek dosya ve klasörleri seç"
        if panel.runModal() == .OK { showCompose(with: panel.urls) }
    }

    // MARK: Window plumbing

    private func configure<Content: View>(_ window: NSWindow, content: Content, size: NSSize) {
        let hosting = NSHostingController(rootView: content.environment(\.window, window))
        hosting.sceneBridgingOptions = [.all]
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private func cascade(_ window: NSWindow) {
        if let key = NSApp.keyWindow, key !== window, key.isVisible {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
        } else {
            window.center()
        }
    }

    /// Closing a window mid-job asks first, then cancels and waits for the cleanup.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let worker = workers[ObjectIdentifier(sender)], worker.isBusy else { return true }
        let alert = NSAlert()
        alert.messageText = "\(worker.busyTitle)…"
        alert.informativeText = "Pencereyi kapatırsan işlem iptal edilir ve yarım kalan dosyalar silinir."
        alert.addButton(withTitle: "İptal Et ve Kapat")
        alert.addButton(withTitle: "Devam Et")
        Task {
            guard await alert.beginSheetModal(for: sender) == .alertFirstButtonReturn else { return }
            await worker.cancelAndWait()
            sender.close()
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        ActiveArchive.shared.model = archives.values.first { $0.window === window }?.model
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        workers[ObjectIdentifier(window)] = nil
        if window === home {
            home = nil
        } else if let entry = archives.first(where: { $0.value.window === window }) {
            entry.value.model.close()
            if ActiveArchive.shared.model === entry.value.model { ActiveArchive.shared.model = nil }
            archives[entry.key] = nil
        } else {
            others.remove(window)
        }
        // Drop the SwiftUI tree so models are released with the window.
        DispatchQueue.main.async { window.contentViewController = nil }
    }
}

/// The archive window menu commands act on.
@MainActor
@Observable
final class ActiveArchive {
    static let shared = ActiveArchive()
    var model: ArchiveModel?
}

/// Archive windows sit in the responder chain and drive the shared Quick Look panel.
final class ArchiveWindow: NSWindow, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    weak var model: ArchiveModel?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model?.quickLookItems.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let items = model?.quickLookItems, items.indices.contains(index) else { return nil }
        return items[index] as NSURL
    }

    /// Arrow keys in the panel move the selection in the list, like Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [123, 124, 125, 126].contains(event.keyCode) else { return false }
        firstResponder?.keyDown(with: event)
        return true
    }
}
