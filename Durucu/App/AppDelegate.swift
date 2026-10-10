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
        alert.messageText = busy.count == 1 ? "\(busy[0].busyTitle)…" : String(localized: "\(busy.count) tasks are running")
        alert.informativeText = String(localized: "If you quit, they're cancelled and any partial files are removed.")
        alert.addButton(withTitle: String(localized: "Cancel and Quit"))
        alert.addButton(withTitle: String(localized: "Keep Working"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            for worker in busy { await worker.cancelAndWait() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        PreviewStore.purgeAll()
        if Relaunch.isRequested {
            // A detached shell outlives this process and opens the app again once it has exited.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
            try? relaunch.run()
        }
    }


    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "New Archive…"), action: #selector(newArchiveFromDock), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Open Archive…"), action: #selector(openFromDock), keyEquivalent: "").target = self
        return menu
    }

    @objc private func newArchiveFromDock() { WindowManager.shared.chooseFilesToCompress() }
    @objc private func openFromDock() { WindowManager.shared.chooseArchivesToOpen() }
}

/// Quits and opens the app again, e.g. to switch languages. The reopen happens in
/// `applicationWillTerminate`, so a quit the user cancels doesn't leave two copies running.
@MainActor
enum Relaunch {
    static private(set) var isRequested = false

    static func now() {
        isRequested = true
        NSApp.terminate(nil)
        // Still running: the user kept a busy window open.
        isRequested = false
    }
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
