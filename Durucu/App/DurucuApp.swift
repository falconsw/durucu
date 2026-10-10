import SwiftUI

@main
struct DurucuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            DurucuCommands()
        }
    }
}

struct DurucuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Yeni Arşiv…") { WindowManager.shared.chooseFilesToCompress() }
                .keyboardShortcut("n")
            Button("Aç…") { WindowManager.shared.chooseArchivesToOpen() }
                .keyboardShortcut("o")
            RecentArchivesMenu()
        }
        CommandMenu("Arşiv") {
            ArchiveMenu()
        }
        CommandGroup(before: .windowList) {
            Button("Karşılama Ekranı") { WindowManager.shared.showHome() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
    }
}

private struct RecentArchivesMenu: View {
    private var recents = RecentArchives.shared

    var body: some View {
        Menu("Son Açılanlar") {
            ForEach(recents.urls, id: \.self) { url in
                Button(url.lastPathComponent) { WindowManager.shared.open([url]) }
            }
            if !recents.urls.isEmpty {
                Divider()
            }
            Button("Listeyi Temizle") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }
}

/// Acts on whichever archive window is key.
private struct ArchiveMenu: View {
    private var active = ActiveArchive.shared

    var body: some View {
        let model = active.model
        let hasSelection = !(model?.selection.isEmpty ?? true)
        Button(hasSelection ? "Seçilenleri Çıkart" : "Tümünü Çıkart") {
            model?.extract(hasSelection ? .selection : .all)
        }
        .keyboardShortcut("e")
        .disabled(model?.phase != .ready || model?.job != nil)
        Button(hasSelection ? "Seçilenleri Farklı Konuma Çıkart…" : "Tümünü Farklı Konuma Çıkart…") {
            model?.extract(hasSelection ? .selection : .all, chooseDestination: true)
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(model?.phase != .ready || model?.job != nil)

        Divider()

        Button("Arşive Ekle…") { model?.chooseFilesToAdd() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!(model?.canEdit ?? false))
        Button("Arşivden Sil…") { model?.requestDeleteSelection() }
            .keyboardShortcut(.delete)
            .disabled(!(model?.canEdit ?? false) || !hasSelection)

        Divider()

        Button("Aç") { if let model { model.activate(model.selection) } }
            .keyboardShortcut(.downArrow)
            .disabled(!hasSelection)
        Button("Hızlı Bakış") { model?.toggleQuickLook() }
            .keyboardShortcut("y")
            .disabled(!hasSelection)

        Divider()

        Button("Geri") { model?.goBack() }
            .keyboardShortcut("[")
            .disabled(!(model?.canGoBack ?? false))
        Button("İleri") { model?.goForward() }
            .keyboardShortcut("]")
            .disabled(!(model?.canGoForward ?? false))
        Button("Üst Klasör") { model?.goUp() }
            .keyboardShortcut(.upArrow)
            .disabled(!(model?.canGoUp ?? false))

        Divider()

        Button((model?.isInspectorPresented ?? false) ? "Bilgi Panelini Gizle" : "Bilgi Panelini Göster") {
            model?.isInspectorPresented.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(model == nil)
        Button((model?.showsMacMetadata ?? false) ? "macOS Artıklarını Gizle" : "macOS Artıklarını Göster") {
            model?.showsMacMetadata.toggle()
        }
        .disabled(model == nil)
    }
}
