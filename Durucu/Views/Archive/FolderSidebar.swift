import SwiftUI

struct FolderSidebar: View {
    @Bindable var model: ArchiveModel

    var body: some View {
        List(selection: Binding<Int?>(
            get: { model.isSearching ? nil : model.currentFolder },
            set: { if let id = $0 { model.navigate(to: id) } }
        )) {
            Section("Klasörler") {
                ForEach(model.outline) { folder in
                    FolderRow(folder: folder, model: model)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SummaryCard(model: model)
                .padding(10)
        }
    }
}

private struct FolderRow: View {
    let folder: FolderOutline
    @Bindable var model: ArchiveModel

    var body: some View {
        if let children = folder.children {
            DisclosureGroup(isExpanded: Binding(
                get: { model.expandedFolders.contains(folder.id) },
                set: { expanded in
                    if expanded { model.expandedFolders.insert(folder.id) } else { model.expandedFolders.remove(folder.id) }
                }
            )) {
                ForEach(children) { child in
                    FolderRow(folder: child, model: model)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            Text(folder.name).lineLimit(1)
        } icon: {
            Image(systemName: folder.id == ArchiveTree.rootID ? "archivebox.fill" : "folder.fill")
                .foregroundStyle(folder.id == ArchiveTree.rootID ? Color.accentColor : Color.secondary)
        }
        .tag(folder.id)
    }
}

/// Totals for the whole archive at the bottom of the sidebar.
private struct SummaryCard: View {
    let model: ArchiveModel

    var body: some View {
        let root = model.tree.root
        HStack(spacing: 12) {
            if root.savings >= 0 {
                SavingsRing(savings: root.savings, lineWidth: 5)
                    .frame(width: 46, height: 46)
            } else {
                Image(nsImage: FileIcons.icon(for: model.url))
                    .resizable()
                    .frame(width: 42, height: 42)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    FormatBadge(text: model.info?.formatName ?? "")
                    if model.info?.hasEncryptedEntries == true {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Şifreli dosyalar içeriyor")
                    }
                }
                Text("\(Format.count(root.fileCount)) dosya · \(Format.count(root.folderCount)) klasör")
                    .font(.caption)
                if let info = model.info {
                    Text("\(Format.bytes(root.size)) → \(Format.bytes(info.archiveSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
