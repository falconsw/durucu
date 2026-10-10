import SwiftUI

struct ArchiveWindowView: View {
    @Bindable var model: ArchiveModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading(let fraction):
                LoadingView(url: model.url, fraction: fraction)
            case .failed(let message):
                FailureView(url: model.url, message: message) { model.load() }
            case .ready:
                ArchiveBrowser(model: model)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
        .navigationTitle(model.archiveName)
        .navigationSubtitle(model.subtitle)
        .sheet(item: $model.passwordRequest) { request in
            PasswordSheet(archiveName: model.archiveName, isRetry: request.isRetry) { value in
                model.submitPassword(value)
            } onCancel: {
                model.cancelPasswordRequest()
            }
        }
        .alert(
            "Bir sorun çıktı",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("Tamam", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

private struct ArchiveBrowser: View {
    @Bindable var model: ArchiveModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            FolderSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            VStack(spacing: 0) {
                PathBar(model: model)
                EntryTable(model: model)
                StatusBar(model: model)
            }
            .overlay {
                if isDropTargeted, model.canEdit {
                    DropToAddOverlay(folderName: model.currentNode.id == ArchiveTree.rootID ? model.archiveName : model.currentNode.name)
                }
            }
            .overlay(alignment: .bottom) {
                ArchiveOverlays(model: model)
                    .padding(.bottom, 40)
            }
            .fileDrop(isTargeted: $isDropTargeted) { model.add($0) }
            .alert(
                "Aynı adda öğe var",
                isPresented: Binding(get: { model.pendingAddition != nil }, set: { if !$0 { model.pendingAddition = nil } }),
                presenting: model.pendingAddition
            ) { pending in
                Button("Değiştir", role: .destructive) { model.performAddition(pending, replacing: true) }
                Button("İkisini de Koru") { model.performAddition(pending, replacing: false) }
                Button("Vazgeç", role: .cancel) { model.pendingAddition = nil }
            } message: { pending in
                Text(pending.conflicts.count == 1
                    ? "“\(pending.conflicts[0])” bu klasörde zaten var. Yenisiyle değiştirilsin mi?"
                    : "\(pending.conflicts.count) öğe bu klasörde zaten var. Yenileriyle değiştirilsin mi?")
            }
            .inspector(isPresented: $model.isInspectorPresented) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Arşivde ara")
        .toolbar { ArchiveToolbar(model: model) }
        .onChange(of: model.selection) { model.selectionDidChange() }
        .alert(
            deletionTitle,
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Sil", role: .destructive) { model.confirmDeletion() }
            Button("Vazgeç", role: .cancel) { model.pendingDeletion = nil }
        } message: { _ in
            Text(model.info?.hasEncryptedEntries == true
                ? "Arşiv yeniden yazılır ve şifreli dosyalar AES-256 ile yeniden şifrelenir. Önceki sürüm Çöp Sepeti'ne taşınır."
                : "Arşiv yeniden yazılır. Önceki sürüm Çöp Sepeti'ne taşınır.")
        }
    }

    private var deletionTitle: String {
        guard let nodes = model.pendingDeletion?.nodes else { return "" }
        return nodes.count == 1 ? "“\(nodes[0].name)” arşivden silinsin mi?" : "\(nodes.count) öğe arşivden silinsin mi?"
    }
}

private struct DropToAddOverlay: View {
    let folderName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            DropHighlight(isActive: true, cornerRadius: 18)
            Label("“\(folderName)” içine ekle", systemImage: "plus.circle.fill")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.2)), in: .capsule)
        }
        .padding(10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

private struct ArchiveToolbar: ToolbarContent {
    @Bindable var model: ArchiveModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Geri", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Geri")
            Button { model.goForward() } label: { Label("İleri", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("İleri")
            Button { model.goUp() } label: { Label("Üst Klasör", systemImage: "arrow.turn.left.up") }
                .disabled(!model.canGoUp)
                .help("Üst klasör (⌘↑)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFilesToAdd() } label: { Label("Ekle", systemImage: "plus") }
                .disabled(!model.canEdit)
                .help(model.editUnavailableReason ?? "Bu klasöre dosya ekle (⇧⌘A)")
            Button { model.requestDeleteSelection() } label: { Label("Sil", systemImage: "trash") }
                .disabled(!model.canEdit || model.selection.isEmpty)
                .help(model.editUnavailableReason ?? "Seçilenleri arşivden sil (⌘⌫)")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button { model.toggleQuickLook() } label: { Label("Hızlı Bakış", systemImage: "eye") }
                .disabled(model.selection.isEmpty)
                .help("Hızlı Bakış (Boşluk)")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Tümünü Çıkart") { model.extract(.all) }
                Button("Seçilenleri Çıkart") { model.extract(.selection) }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("Tümünü Farklı Konuma Çıkart…") { model.extract(.all, chooseDestination: true) }
                Button("Seçilenleri Farklı Konuma Çıkart…") { model.extract(.selection, chooseDestination: true) }
                    .disabled(model.selection.isEmpty)
            } label: {
                Label(model.selection.isEmpty ? "Tümünü Çıkart" : "Seçileni Çıkart", systemImage: "arrow.down.to.line")
            } primaryAction: {
                model.extract(model.selection.isEmpty ? .all : .selection)
            }
            .menuIndicator(.visible)
            .help("Çıkart (⌘E) · Farklı konuma (⌥⌘E)")
            .disabled(model.job != nil)
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button { model.isInspectorPresented.toggle() } label: { Label("Bilgi", systemImage: "sidebar.trailing") }
                .help("Bilgi panelini göster/gizle (⌥⌘I)")
        }
    }
}

/// Clickable trail from the archive root to the current folder.
private struct PathBar: View {
    @Bindable var model: ArchiveModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isSearching {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("“\(model.searchText)” için \(Format.count(model.rows.count)) sonuç")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .foregroundStyle(.tertiary)
                            }
                            crumb(node, isLast: index == model.breadcrumb.count - 1)
                        }
                    }
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.trailing, for: .initialOffset)
                .defaultScrollAnchor(.trailing, for: .sizeChanges)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func crumb(_ node: ArchiveNode, isLast: Bool) -> some View {
        Button {
            model.navigate(to: node.id)
        } label: {
            HStack(spacing: 5) {
                Image(nsImage: node.id == ArchiveTree.rootID ? FileIcons.icon(for: model.url) : FileIcons.folder)
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(node.id == ArchiveTree.rootID ? model.archiveName : node.name)
                    .fontWeight(isLast ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? .primary : .secondary)
    }
}

private struct StatusBar: View {
    let model: ArchiveModel

    var body: some View {
        HStack(spacing: 8) {
            Text(leading)
            Spacer()
            if model.password != nil {
                Label("Şifre girildi", systemImage: "lock.open.fill")
                    .labelStyle(.titleAndIcon)
            }
            Text(trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private var leading: String {
        let selected = model.selectedNodes
        if selected.isEmpty {
            return "\(Format.count(model.rows.count)) öğe"
        }
        let bytes = selected.reduce(Int64(0)) { $0 + $1.size }
        return "\(Format.count(selected.count)) / \(Format.count(model.rows.count)) öğe seçildi · \(Format.bytes(bytes))"
    }

    private var trailing: String {
        let root = model.tree.root
        var parts = ["\(Format.count(root.fileCount)) dosya", "açılmış \(Format.bytes(root.size))"]
        if let info = model.info { parts.append("arşiv \(Format.bytes(info.archiveSize))") }
        if root.savings >= 0 { parts.append("%\(Int((root.savings * 100).rounded())) kazanç") }
        return parts.joined(separator: " · ")
    }
}

private struct LoadingView: View {
    let url: URL
    let fraction: Double

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: FileIcons.icon(for: url))
                .resizable()
                .frame(width: 84, height: 84)
                .symbolEffect(.pulse)
            Text(url.lastPathComponent)
                .font(.title3.weight(.semibold))
            ProgressView(value: fraction > 0.01 ? fraction : nil)
                .progressViewStyle(.linear)
                .frame(width: 240)
            Text("Arşiv okunuyor…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let url: URL
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Arşiv açılamadı", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            HStack {
                Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Tekrar Dene", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
