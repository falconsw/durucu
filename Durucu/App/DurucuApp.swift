import SwiftUI

@main
struct DurucuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Runs before any window or menu loads, so the chosen language applies to this launch.
        AppLanguage.apply()
    }

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
            Button("New Archive…") { WindowManager.shared.chooseFilesToCompress() }
                .keyboardShortcut("n")
            Button("Open…") { WindowManager.shared.chooseArchivesToOpen() }
                .keyboardShortcut("o")
            RecentArchivesMenu()
        }
        CommandMenu("Archive") {
            ArchiveMenu()
        }
        CommandGroup(before: .windowList) {
            Button("Welcome Window") { WindowManager.shared.showHome() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Divider()
        }
    }
}

private struct RecentArchivesMenu: View {
    private var recents = RecentArchives.shared

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                Button(url.lastPathComponent) { WindowManager.shared.open([url]) }
            }
            if !recents.urls.isEmpty {
                Divider()
            }
            Button("Clear Menu") { recents.clear() }
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
        Button(hasSelection ? String(localized: "Extract Selected") : String(localized: "Extract All")) {
            model?.extract(hasSelection ? .selection : .all)
        }
        .keyboardShortcut("e")
        .disabled(model?.phase != .ready || model?.job != nil)
        Button(hasSelection ? String(localized: "Extract Selected To…") : String(localized: "Extract All To…")) {
            model?.extract(hasSelection ? .selection : .all, chooseDestination: true)
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(model?.phase != .ready || model?.job != nil)

        Divider()

        Button("Add to Archive…") { model?.chooseFilesToAdd() }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!(model?.canEdit ?? false))
        Button("Delete from Archive…") { model?.requestDeleteSelection() }
            .keyboardShortcut(.delete)
            .disabled(!(model?.canEdit ?? false) || !hasSelection)

        Divider()

        Button("Open") { if let model { model.activate(model.selection) } }
            .keyboardShortcut(.downArrow)
            .disabled(!hasSelection)
        Button("Quick Look") { model?.toggleQuickLook() }
            .keyboardShortcut("y")
            .disabled(!hasSelection)

        Divider()

        Button("Back") { model?.goBack() }
            .keyboardShortcut("[")
            .disabled(!(model?.canGoBack ?? false))
        Button("Forward") { model?.goForward() }
            .keyboardShortcut("]")
            .disabled(!(model?.canGoForward ?? false))
        Button("Enclosing Folder") { model?.goUp() }
            .keyboardShortcut(.upArrow)
            .disabled(!(model?.canGoUp ?? false))

        Divider()

        Button((model?.isInspectorPresented ?? false) ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) {
            model?.isInspectorPresented.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(model == nil)
        Button((model?.showsMacMetadata ?? false) ? String(localized: "Hide macOS Clutter") : String(localized: "Show macOS Clutter")) {
            model?.showsMacMetadata.toggle()
        }
        .disabled(model == nil)
    }
}
