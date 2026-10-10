import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Extracting", systemImage: "arrow.down.doc") { ExtractSettings() }
            Tab("Compressing", systemImage: "shippingbox") { CompressSettings() }
            Tab("Finder", systemImage: "macwindow") { IntegrationSettings() }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.language) private var language = AppLanguage.english
    @AppStorage(Pref.openBehavior) private var openBehavior = OpenBehavior.browse
    @AppStorage(Pref.showMacMetadata) private var showMacMetadata = false
    @AppStorage(Pref.autoPreview) private var autoPreview = true

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .onChange(of: language) { AppLanguage.apply() }
                if language != AppLanguage.active {
                    HStack {
                        Text("Dürücü needs to restart to switch languages.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { Relaunch.now() }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            Section {
                Picker("When I double-click an archive", selection: $openBehavior) {
                    ForEach(OpenBehavior.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Toggle(isOn: $autoPreview) {
                    Text("Preview the selected file in the inspector")
                    Text("Files up to 200 MB are extracted in the background.")
                }
                Toggle(isOn: $showMacMetadata) {
                    Text("Show macOS clutter")
                    Text("The `__MACOSX` folder, `._` and `.DS_Store` files. Applies to newly opened windows.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}

private struct ExtractSettings: View {
    @AppStorage(Pref.extractDestination) private var destination = ExtractDestination.beside
    @AppStorage(Pref.customDestination) private var customPath = ""
    @AppStorage(Pref.smartFolder) private var smartFolder = true
    @AppStorage(Pref.revealAfterExtract) private var reveal = true
    @AppStorage(Pref.trashAfterQuickExtract) private var trashAfter = false

    var body: some View {
        Form {
            Picker("Put extracted files", selection: $destination) {
                ForEach(ExtractDestination.allCases) { Text($0.title).tag($0) }
            }
            if destination == .custom {
                LabeledContent("Folder") {
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
                    } label: {
                        Label(FileManager.default.displayName(atPath: customPath), systemImage: "folder")
                    }
                    .help(customPath)
                }
            }
            Toggle(isOn: $smartFolder) {
                Text("Smart folder")
                Text("If the archive already holds a single folder, don't wrap it in another one.")
            }
            Toggle("Show in Finder when done", isOn: $reveal)
            Toggle(isOn: $trashAfter) {
                Text("Move the archive to the Trash after extracting right away")
                Text("Only for “Extract it right away” and the Finder service.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}

private struct CompressSettings: View {
    @AppStorage(Pref.defaultFormat) private var format = OutputFormat.zip
    @AppStorage(Pref.defaultLevel) private var level = CompressionLevel.balanced
    @AppStorage(Pref.excludeMacMetadata) private var exclude = true

    var body: some View {
        Form {
            Picker("Default format", selection: $format) {
                ForEach(OutputFormat.creatable) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Default compression", selection: $level) {
                ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $exclude) {
                Text("Leave out macOS clutter")
                Text("`.DS_Store`, `._` files and `__MACOSX` aren't added to archives.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

private struct IntegrationSettings: View {
    @State private var refresh = 0
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                ForEach(DefaultApps.types) { type in
                    let isOurs = DefaultApps.isDefault(for: type)
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(DefaultApps.handlerName(for: type))
                                .foregroundStyle(isOurs ? Color.green : Color.secondary)
                            if !isOurs {
                                Button("Use Dürücü") {
                                    Task {
                                        await DefaultApps.makeDefault([type])
                                        refresh += 1
                                    }
                                }
                                .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    } label: {
                        Text(type.title)
                        Text(type.extensions)
                    }
                }
            } header: {
                Text("App that opens them in Finder")
            } footer: {
                HStack {
                    Spacer()
                    Button {
                        isWorking = true
                        Task {
                            await DefaultApps.makeDefault()
                            isWorking = false
                            refresh += 1
                        }
                    } label: {
                        Text("Open All with Dürücü")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || DefaultApps.isDefaultForAll)
                }
            }
            .id(refresh)

            Section("Context menu") {
                Label {
                    Text("Right-click files in Finder and choose **Quick Actions › Compress with Dürücü** or **Extract Here with Dürücü**. If they're missing, turn them on in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                } icon: {
                    Image(systemName: "contextualmenu.and.cursorarrow")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}
