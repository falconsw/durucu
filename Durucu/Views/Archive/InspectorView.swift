import SwiftUI

struct InspectorView: View {
    let model: ArchiveModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let nodes = model.selectedNodes
                switch nodes.count {
                case 0:
                    ArchiveSummary(model: model)
                case 1:
                    NodeDetails(node: nodes[0], model: model)
                default:
                    MultipleSelection(nodes: nodes, model: model)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ArchiveSummary: View {
    let model: ArchiveModel

    var body: some View {
        let root = model.tree.root
        VStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: model.url))
                .resizable()
                .frame(width: 96, height: 96)
            Text(model.archiveName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let info = model.info { FormatBadge(text: info.displayFormat) }
        }
        .frame(maxWidth: .infinity)

        if root.savings >= 0, let info = model.info {
            HStack(spacing: 14) {
                SavingsRing(savings: root.savings, lineWidth: 7)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space saved").font(.callout.weight(.semibold))
                    Text("\(Format.bytes(root.size)) of content fits in a \(Format.bytes(info.archiveSize)) archive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            InfoRow(label: "Files", value: Format.count(root.fileCount))
            InfoRow(label: "Folders", value: Format.count(root.folderCount))
            InfoRow(label: "Unpacked", value: Format.bytes(root.size))
            if let info = model.info {
                InfoRow(label: "Archive", value: Format.bytes(info.archiveSize))
                InfoRow(label: "Password", value: info.hasEncryptedEntries ? String(localized: "Has encrypted files") : String(localized: "None"))
            }
            InfoRow(label: "Location", value: model.url.deletingLastPathComponent().path)
        }

        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
            Spacer()
            Button("Extract All") { model.extract(.all) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }
}

private struct NodeDetails: View {
    let node: ArchiveNode
    let model: ArchiveModel
    @AppStorage(Pref.autoPreview) private var autoPreview = true
    @State private var previewURL: URL?
    @State private var isLoading = false

    private static let previewLimit: Int64 = 200 * 1024 * 1024

    var body: some View {
        preview
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .task(id: node.id) { await loadPreview() }

        VStack(alignment: .leading, spacing: 4) {
            Text(node.name)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(4)
            Text(node.kindDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        if node.savings >= 0, let packed = node.compressedSize {
            HStack(spacing: 12) {
                SavingsRing(savings: node.savings, lineWidth: 5)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(Format.bytes(node.size)) → \(Format.bytes(packed))")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    Text(node.method ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            InfoRow(label: "Size", value: Format.bytes(node.size))
            if let packed = node.compressedSize, !node.isDirectory {
                InfoRow(label: "Compressed", value: Format.bytes(packed))
            }
            if node.isDirectory {
                InfoRow(label: "Contents", value: String(localized: "\(node.fileCount) files, \(node.folderCount) folders"))
            }
            InfoRow(label: "Modified", value: Format.date(node.modified))
            if let method = node.method, !node.isDirectory { InfoRow(label: "Method", value: method) }
            if let crc = node.crc32, !node.isDirectory {
                InfoRow(label: "CRC32", value: String(format: "%08X", crc), monospaced: true)
            }
            InfoRow(label: "Permissions", value: Format.permissions(node.permissions), monospaced: true)
            if let target = node.linkTarget { InfoRow(label: "Target", value: target) }
            if node.isEncrypted { InfoRow(label: "Password", value: String(localized: "Encrypted")) }
            InfoRow(label: "Path", value: node.path)
        }

        HStack {
            Button(node.isDirectory ? String(localized: "Open Folder") : String(localized: "Open")) { model.activate([node.id]) }
            Spacer()
            Button("Extract") { model.extract(.selection) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewURL {
            QuickLookView(url: previewURL)
        } else {
            ZStack {
                Image(nsImage: FileIcons.icon(forName: node.name, isDirectory: node.isDirectory, isSymlink: node.isSymlink))
                    .resizable()
                    .frame(width: 112, height: 112)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .offset(y: 78)
                } else if node.isEncrypted, model.password == nil, !node.isDirectory {
                    Label("Enter the password to preview", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .offset(y: 80)
                }
            }
        }
    }

    private func loadPreview() async {
        previewURL = nil
        guard autoPreview, !node.isDirectory, !node.isSymlink, node.size <= Self.previewLimit,
              !node.isEncrypted || model.password != nil else { return }
        // Brief pause so arrowing through a long list doesn't extract every file.
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        let url = try? await model.previews.file(for: node, password: model.password)
        guard !Task.isCancelled else { return }
        previewURL = url
    }
}

private struct MultipleSelection: View {
    let nodes: [ArchiveNode]
    let model: ArchiveModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ForEach(Array(nodes.prefix(3).enumerated().reversed()), id: \.offset) { index, node in
                    Image(nsImage: FileIcons.icon(forName: node.name, isDirectory: node.isDirectory, isSymlink: node.isSymlink))
                        .resizable()
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(Double(index) * 8 - 8))
                        .offset(x: CGFloat(index) * 14 - 14)
                }
            }
            .frame(height: 110)
            Text("\(nodes.count) items selected")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)

        let bytes = nodes.reduce(Int64(0)) { $0 + $1.size }
        let packed = nodes.allSatisfy { $0.compressedSize != nil } ? nodes.reduce(Int64(0)) { $0 + ($1.compressedSize ?? 0) } : nil
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            InfoRow(label: "Files", value: Format.count(nodes.reduce(0) { $0 + ($1.isDirectory ? $1.fileCount : 1) }))
            InfoRow(label: "Size", value: Format.bytes(bytes))
            if let packed { InfoRow(label: "Compressed", value: Format.bytes(packed)) }
        }

        HStack {
            Button("Quick Look") { model.toggleQuickLook() }
            Spacer()
            Button("Extract Selected") { model.extract(.selection) }
                .buttonStyle(.borderedProminent)
        }
    }
}
