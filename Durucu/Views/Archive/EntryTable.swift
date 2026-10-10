import SwiftUI

struct EntryTable: View {
    @Bindable var model: ArchiveModel
    @State private var columns = TableColumnCustomization<ArchiveNode>()

    var body: some View {
        let rows = model.rows
        Table(of: ArchiveNode.self, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { node in
                NameCell(node: node, showsLocation: model.isSearching)
            }
            .width(min: 200, ideal: 280)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Size", value: \.size) { node in
                Text(Format.bytes(node.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 84)
            .alignment(.trailing)
            .customizationID("size")

            TableColumn("Compressed", value: \.compressedSortKey) { node in
                Text(node.compressedSize.map(Format.bytes) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 104)
            .alignment(.trailing)
            .customizationID("packed")

            TableColumn("Saved", value: \.savings) { node in
                SavingsBar(savings: node.savings)
            }
            .width(min: 84, ideal: 96)
            .customizationID("savings")

            TableColumn("Date Modified", value: \.modifiedSortKey) { node in
                Text(Format.date(node.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 136)
            .customizationID("modified")

            TableColumn("Kind", value: \.kindDescription) { node in
                Text(node.kindDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            .customizationID("kind")
        } rows: {
            ForEach(rows) { node in
                TableRow(node)
                    .itemProvider { model.itemProvider(for: node) }
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            RowMenu(model: model, ids: ids)
        } primaryAction: { ids in
            model.activate(ids)
        }
        .onDeleteCommand { model.requestDeleteSelection() }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.activate(model.selection)
            return .handled
        }
        .overlay {
            if rows.isEmpty {
                if model.isSearching {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView(
                        "This folder is empty",
                        systemImage: "folder",
                        description: Text(model.canEdit ? String(localized: "Drag files here to add them.") : "")
                    )
                }
            }
        }
        .onAppear {
            if !model.hasCompressedSizes {
                columns[visibility: "packed"] = .hidden
                columns[visibility: "savings"] = .hidden
            }
        }
    }
}

private struct NameCell: View {
    let node: ArchiveNode
    let showsLocation: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(forName: node.name, isDirectory: node.isDirectory, isSymlink: node.isSymlink))
                .resizable()
                .frame(width: 18, height: 18)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsLocation, !node.parentPath.isEmpty {
                Text(node.parentPath)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if node.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Encrypted")
            }
        }
    }
}

private struct RowMenu: View {
    let model: ArchiveModel
    let ids: Set<Int>

    var body: some View {
        let nodes = ids.compactMap { model.tree.node($0) }
        if !nodes.isEmpty {
            Button(nodes.count == 1 && nodes[0].isDirectory ? String(localized: "Open Folder") : String(localized: "Open")) {
                model.activate(ids)
            }
            Button("Quick Look") {
                model.selection = ids
                model.toggleQuickLook()
            }
            Divider()
            Button("Extract") {
                model.selection = ids
                model.extract(.selection)
            }
            Button("Extract To…") {
                model.selection = ids
                model.extract(.selection, chooseDestination: true)
            }
            Divider()
            if model.isSearching, nodes.count == 1 {
                Button("Show in Enclosing Folder") { model.reveal(nodes[0]) }
            }
            Button(nodes.count == 1 ? String(localized: "Copy Path") : String(localized: "Copy Paths")) { model.copyPath(nodes) }
            if model.canEdit {
                Divider()
                if nodes.count == 1, nodes[0].isDirectory {
                    Button("Add to This Folder…") { model.chooseFilesToAdd(into: nodes[0].id) }
                }
                Button("Delete from Archive…", role: .destructive) {
                    model.selection = ids
                    model.requestDeleteSelection()
                }
            }
        }
    }
}
