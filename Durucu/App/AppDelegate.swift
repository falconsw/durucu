import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFilesAtLaunch = false
    private let services = ServiceProvider()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        PreviewStore.purgeAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        DefaultApps.claimOnFirstLaunch()
        #if DEBUG
        DebugSnapshots.startIfRequested()
        #endif
        // Finder delivers documents during launch; give that a turn before showing the home window.
        DispatchQueue.main.async { [self] in
            if !openedFilesAtLaunch, !WindowManager.shared.hasOpenWindows {
                WindowManager.shared.showHome()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        WindowManager.shared.open(urls, fromFinder: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showHome() }
        return true
    }

    /// The close button on the last window quits Dürücü.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = WindowManager.shared.busyWorkers
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = busy.count == 1 ? "\(busy[0].busyTitle)…" : "\(busy.count) işlem sürüyor"
        alert.informativeText = "Çıkarsan iptal edilir ve yarım kalan dosyalar silinir."
        alert.addButton(withTitle: "İptal Et ve Çık")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            for worker in busy { await worker.cancelAndWait() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        PreviewStore.purgeAll()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Yeni Arşiv…", action: #selector(newArchiveFromDock), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Arşiv Aç…", action: #selector(openFromDock), keyEquivalent: "").target = self
        return menu
    }

    @objc private func newArchiveFromDock() { WindowManager.shared.chooseFilesToCompress() }
    @objc private func openFromDock() { WindowManager.shared.chooseArchivesToOpen() }
}

/// Finder → Services / Quick Actions entries declared under NSServices in Info.plist.
@MainActor
final class ServiceProvider: NSObject {
    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        NSApp.activate()
        WindowManager.shared.showCompose(with: urls)
    }

    @objc func extractArchives(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        for url in fileURLs(from: pasteboard) where FileNaming.looksLikeArchive(url) {
            WindowManager.shared.quickExtract(url, destination: url.deletingLastPathComponent())
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
