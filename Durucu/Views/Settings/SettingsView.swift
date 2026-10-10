import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Genel", systemImage: "gearshape") { GeneralSettings() }
            Tab("Çıkartma", systemImage: "arrow.down.doc") { ExtractSettings() }
            Tab("Sıkıştırma", systemImage: "shippingbox") { CompressSettings() }
            Tab("Finder", systemImage: "macwindow") { IntegrationSettings() }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.openBehavior) private var openBehavior = OpenBehavior.browse
    @AppStorage(Pref.showMacMetadata) private var showMacMetadata = false
    @AppStorage(Pref.autoPreview) private var autoPreview = true

    var body: some View {
        Form {
            Picker("Bir arşive çift tıkladığımda", selection: $openBehavior) {
                ForEach(OpenBehavior.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Toggle(isOn: $autoPreview) {
                Text("Seçili dosyayı bilgi panelinde önizle")
                Text("200 MB'a kadar olan dosyalar arka planda açılır.")
            }
            Toggle(isOn: $showMacMetadata) {
                Text("macOS artıklarını göster")
                Text("__MACOSX klasörü, ._ ve .DS_Store dosyaları. Yeni açılan pencerelerde geçerli olur.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
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
            Picker("Çıkartılan dosyalar", selection: $destination) {
                ForEach(ExtractDestination.allCases) { Text($0.title).tag($0) }
            }
            if destination == .custom {
                LabeledContent("Klasör") {
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
                Text("Akıllı klasör")
                Text("Arşivin içinde zaten tek bir klasör varsa onu ayrıca sarmalamaz.")
            }
            Toggle("Bitince Finder'da göster", isOn: $reveal)
            Toggle(isOn: $trashAfter) {
                Text("Hemen çıkartınca arşivi Çöp Sepeti'ne taşı")
                Text("Yalnızca “Hemen çıkart” davranışında ve Finder servisinde.")
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
            Picker("Varsayılan biçim", selection: $format) {
                ForEach(OutputFormat.creatable) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Varsayılan sıkıştırma", selection: $level) {
                ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $exclude) {
                Text("macOS artıklarını dışarıda bırak")
                Text(".DS_Store, ._ dosyaları ve __MACOSX arşive eklenmez.")
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
                                Button("Dürücü yap") {
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
                Text("Finder'da açan uygulama")
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
                        Text("Hepsini Dürücü ile aç")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || DefaultApps.isDefaultForAll)
                }
            }
            .id(refresh)

            Section("Sağ tık menüsü") {
                Label {
                    Text("Finder'da dosyalara sağ tıklayıp **Hızlı İşlemler › Dürücü ile Dür** ya da **Dürücü ile Buraya Çıkart** seçebilirsin. Görünmüyorsa Sistem Ayarları › Klavye › Klavye Kestirmeleri › Servisler bölümünden aç.")
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
