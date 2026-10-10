import AppKit
import Observation
import Quartz
import UniformTypeIdentifiers

/// State of one archive window: listing, navigation, selection and jobs.
@MainActor
@Observable
final class ArchiveModel {
    enum Phase: Equatable {
        case loading(Double)
        case ready
        case failed(String)
    }

    enum ExtractScope {
        case all, selection
    }

    struct PasswordRequest: Identifiable {
        let id = UUID()
        var isRetry: Bool
        var onSubmit: @MainActor () -> Void
    }

    struct Job {
        var title: String
        var fraction: Double = 0
        var detail: String = ""
    }

    struct PendingAddition: Identifiable {
        let id = UUID()
        var urls: [URL]
        var folderID: Int
        var conflicts: [String]
    }

    struct PendingDeletion: Identifiable {
        let id = UUID()
        var nodes: [ArchiveNode]
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var outputs: [URL]
    }

    let url: URL
    let previews: PreviewStore
    weak var window: NSWindow?

    private(set) var phase: Phase = .loading(0)
    private(set) var info: ArchiveInfo?
    private(set) var tree = ArchiveTree.empty
    private(set) var outline: [FolderOutline] = []
    private(set) var currentFolder = ArchiveTree.rootID
    private var backStack: [Int] = []
    private var forwardStack: [Int] = []

    var selection = Set<Int>()
    var searchText = ""
    var sortOrder = [KeyPathComparator(\ArchiveNode.name, comparator: .localizedStandard)]
    var expandedFolders: Set<Int> = [ArchiveTree.rootID]
    var isInspectorPresented = true
    var showsMacMetadata = Pref.bool(Pref.showMacMetadata) {
        didSet { rebuildTree() }
    }

    private(set) var password: String?
    var passwordRequest: PasswordRequest?
    private(set) var job: Job?
    var notice: Notice?
    var errorMessage: String?
    var pendingAddition: PendingAddition?
    var pendingDeletion: PendingDeletion?
    private(set) var quickLookItems: [URL] = []

    private var loadTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        previews = PreviewStore(archive: url)
    }

    // MARK: Derived state

    var archiveName: String { url.lastPathComponent }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasCompressedSizes: Bool { tree.root.compressedSize != nil }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { tree.node(currentFolder)?.parent != nil }
    var currentNode: ArchiveNode { tree.node(currentFolder) ?? tree.root }
    var breadcrumb: [ArchiveNode] { tree.lineage(of: currentFolder) }

    var rows: [ArchiveNode] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = query.isEmpty ? tree.children(of: currentFolder) : tree.search(query)
        let sorted = base.sorted(using: sortOrder)
        return sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory }
    }

    var selectedNodes: [ArchiveNode] {
        selection.compactMap { tree.node($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var subtitle: String {
        guard let info, phase == .ready else { return "" }
        return "\(info.displayFormat) · \(String(localized: "\(tree.root.fileCount) files")) · \(Format.bytes(info.archiveSize))"
    }

    // MARK: Loading

    func load() {
        loadTask?.cancel()
        phase = .loading(0)
        let url = url
        let password = password
        let includeMetadata = showsMacMetadata
        loadTask = Task { [weak self] in
            do {
                let (info, tree) = try await Self.read(url: url, password: password, includeMetadata: includeMetadata) { fraction in
                    Task { @MainActor in
                        guard let self, case .loading = self.phase else { return }
                        self.phase = .loading(fraction)
                    }
                }
                guard let self else { return }
                self.info = info
                self.apply(tree)
                self.phase = .ready
                RecentArchives.shared.note(url)
            } catch ArchiveError.cancelled {
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    @concurrent
    private static func read(
        url: URL, password: String?, includeMetadata: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (ArchiveInfo, ArchiveTree) {
        let info = try ArchiveReader.list(url: url, password: password, progress: progress)
        return (info, ArchiveTree.build(from: info.entries, includeMacMetadata: includeMetadata))
    }

    private func rebuildTree() {
        guard let info else { return }
        apply(ArchiveTree.build(from: info.entries, includeMacMetadata: showsMacMetadata))
    }

    private func apply(_ newTree: ArchiveTree) {
        let previousPath = tree.node(currentFolder)?.path
        tree = newTree
        outline = newTree.folderOutline(rootName: FileNaming.baseName(of: url))
        backStack = []
        forwardStack = []
        selection = []
        // Rewritten archives store NFC names, so compare paths precomposed.
        currentFolder = previousPath.map(\.precomposedStringWithCanonicalMapping).flatMap { path in
            newTree.nodes.first { $0.isDirectory && $0.path.precomposedStringWithCanonicalMapping == path }?.id
        } ?? ArchiveTree.rootID
        // Archives that wrap everything in one folder show that folder unfolded in the sidebar.
        if currentFolder == ArchiveTree.rootID, newTree.root.children.count == 1,
           let only = newTree.node(newTree.root.children[0]), only.isDirectory {
            expandedFolders.insert(only.id)
        }
    }

    // MARK: Navigation

    func navigate(to id: Int) {
        guard id != currentFolder, let node = tree.node(id), node.isDirectory else { return }
        backStack.append(currentFolder)
        forwardStack.removeAll()
        show(id)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentFolder)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentFolder)
        show(next)
    }

    func goUp() {
        guard let parent = tree.node(currentFolder)?.parent else { return }
        let child = currentFolder
        navigate(to: parent)
        selection = [child]
    }

    private func show(_ id: Int) {
        currentFolder = id
        selection = []
        searchText = ""
        for node in tree.lineage(of: id) { expandedFolders.insert(node.id) }
    }

    /// Double-click / Return: folders open in place, files open in their default app.
    func activate(_ ids: Set<Int>) {
        let nodes = ids.compactMap { tree.node($0) }
        if nodes.count == 1, let folder = nodes.first, folder.isDirectory, !isPackage(folder) {
            navigate(to: folder.id)
            return
        }
        withPassword(for: nodes) { [weak self] in
            guard let self else { return }
            Task {
                for node in nodes {
                    do {
                        let file = try await self.previews.file(for: node, password: self.password)
                        NSWorkspace.shared.open(file)
                    } catch {
                        self.handle(error) { self.activate(ids) }
                        return
                    }
                }
            }
        }
    }

    func reveal(_ node: ArchiveNode) {
        searchText = ""
        if let parent = node.parent { navigate(to: parent) }
        selection = [node.id]
    }

    private func isPackage(_ node: ArchiveNode) -> Bool {
        UTType(filenameExtension: (node.name as NSString).pathExtension)?.conforms(to: .package) ?? false
    }

    // MARK: Extraction

    func extract(_ scope: ExtractScope, chooseDestination: Bool = false) {
        guard job == nil, let info else { return }
        let nodes = scope == .selection && !selection.isEmpty ? selectedNodes : nil
        let needsPassword = nodes.map { $0.contains(where: \.isEncrypted) } ?? info.hasEncryptedEntries
        guard !needsPassword || password != nil else {
            requestPassword(isRetry: false) { [weak self] in self?.extract(scope, chooseDestination: chooseDestination) }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            var destination = chooseDestination ? nil : ExtractionService.defaultDestination(for: url)
            if destination == nil {
                destination = await ExtractionService.chooseDestination(for: url, window: window)
            }
            guard let destination else { return }

            let request = ExtractionService.Request(
                archive: url,
                password: password,
                roots: nodes?.map { ExtractionService.Root(path: $0.path, name: $0.name) },
                destination: destination,
                smartFolder: Pref.bool(Pref.smartFolder),
                totalBytes: nodes?.reduce(0) { $0 + $1.size } ?? tree.root.size,
                skipMacMetadata: !showsMacMetadata
            )
            let title = nodes.map {
                $0.count == 1 ? String(localized: "Extracting “\($0[0].name)”") : String(localized: "Extracting \($0.count) items")
            } ?? String(localized: "Extracting archive")
            run(request, title: title) { [weak self] in
                self?.extract(scope, chooseDestination: chooseDestination)
            }
        }
    }

    private func run(_ request: ExtractionService.Request, title: String, retry: @escaping @MainActor () -> Void) {
        job = Job(title: title)
        jobTask = Task { [weak self] in
            do {
                let outputs = try await ExtractionService.run(request) { progress in
                    self?.job?.fraction = progress.fraction
                    self?.job?.detail = progress.currentItem
                }
                guard let self else { return }
                self.job = nil
                self.finished(outputs)
            } catch {
                guard let self else { return }
                self.job = nil
                self.handle(error, retry: retry)
            }
        }
    }

    func cancelJob() {
        jobTask?.cancel()
    }

    private func finished(_ outputs: [URL]) {
        guard !outputs.isEmpty else {
            errorMessage = String(localized: "There was nothing to extract.")
            return
        }
        let message = outputs.count == 1
            ? String(localized: "Extracted “\(outputs[0].lastPathComponent)”")
            : String(localized: "Extracted \(outputs.count) items")
        showNotice(Notice(message: message, outputs: outputs))
        if Pref.bool(Pref.revealAfterExtract) {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    private func showNotice(_ value: Notice) {
        notice = value
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self?.notice?.id == value.id else { return }
            self?.notice = nil
        }
    }

    // MARK: Editing

    /// Format the archive is rewritten in, or `nil` for formats libarchive can only read.
    var editFormat: OutputFormat? { info.flatMap(OutputFormat.init(rewriting:)) }

    var editUnavailableReason: String? {
        guard let info else { return String(localized: "The archive hasn't been read yet.") }
        if editFormat == nil { return String(localized: "\(info.displayFormat) archives are read-only and can't be changed.") }
        if !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
            return String(localized: "Can't write to the folder that contains the archive.")
        }
        return nil
    }

    var canEdit: Bool { phase == .ready && job == nil && editUnavailableReason == nil }

    func chooseFilesToAdd(into folderID: Int? = nil) {
        guard ensureEditable() else { return }
        let folder = tree.node(folderID ?? currentFolder) ?? tree.root
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose files and folders to add to “\(folder.id == ArchiveTree.rootID ? archiveName : folder.name)”")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls, into: folder.id)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Adds files from disk into a folder of the archive (the current one by default).
    func add(_ urls: [URL], into folderID: Int? = nil) {
        guard ensureEditable() else { return }
        // Ignore our own extracted copies (a row dragged back onto the list) and the archive itself.
        let previewRoot = PreviewStore.rootDirectory.standardizedFileURL.path
        let files = urls.filter {
            !$0.standardizedFileURL.path.hasPrefix(previewRoot) && $0.standardizedFileURL != url.standardizedFileURL
        }
        guard !files.isEmpty else { return }
        let folder = tree.node(folderID ?? currentFolder) ?? tree.root
        let existing = Set(tree.children(of: folder.id).map { $0.name.precomposedStringWithCanonicalMapping })
        let conflicts = files.map(\.lastPathComponent).filter { existing.contains($0.precomposedStringWithCanonicalMapping) }
        let addition = PendingAddition(urls: files, folderID: folder.id, conflicts: conflicts)
        if conflicts.isEmpty {
            performAddition(addition, replacing: false)
        } else {
            pendingAddition = addition
        }
    }

    func performAddition(_ addition: PendingAddition, replacing: Bool) {
        pendingAddition = nil
        withEditPassword { [weak self] in self?.runAddition(addition, replacing: replacing) }
    }

    private func runAddition(_ addition: PendingAddition, replacing: Bool) {
        guard let format = editFormat, let folder = tree.node(addition.folderID) else { return }
        let siblings = tree.children(of: folder.id)
        var taken = Set(siblings.map { $0.name.precomposedStringWithCanonicalMapping })
        var names: [URL: String] = [:]
        var deletions: Set<String> = []
        var finalNames: [String] = []

        for source in addition.urls {
            let name = source.lastPathComponent
            var finalName = name
            if let existing = siblings.first(where: { $0.name.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping }) {
                if replacing {
                    deletions.insert(existing.path)
                } else {
                    let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    finalName = FileNaming.uniqueName(name, isDirectory: isDirectory) { taken.contains($0.precomposedStringWithCanonicalMapping) }
                    names[source] = finalName
                }
            }
            taken.insert(finalName.precomposedStringWithCanonicalMapping)
            finalNames.append(finalName)
        }

        let request = EditRequest(
            url: url, format: format, level: Pref.defaultLevelValue, password: password, deletions: deletions,
            sources: addition.urls, prefix: folder.path, names: names, excludeMacMetadata: Pref.bool(Pref.excludeMacMetadata)
        )
        let added = Set(finalNames.map { (folder.path.isEmpty ? $0 : "\(folder.path)/\($0)").precomposedStringWithCanonicalMapping })
        let title = finalNames.count == 1
            ? String(localized: "Adding “\(finalNames[0])”") : String(localized: "Adding \(finalNames.count) items")
        let message = finalNames.count == 1
            ? String(localized: "Added “\(finalNames[0])”") : String(localized: "Added \(finalNames.count) items")
        runEdit(request, title: title, notice: message, select: added) { [weak self] in
            self?.performAddition(addition, replacing: replacing)
        }
    }

    func requestDeleteSelection() {
        guard ensureEditable() else { return }
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        pendingDeletion = PendingDeletion(nodes: nodes)
    }

    func confirmDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        withEditPassword { [weak self] in self?.runDeletion(pending.nodes) }
    }

    private func runDeletion(_ nodes: [ArchiveNode]) {
        guard let format = editFormat else { return }
        let request = EditRequest(
            url: url, format: format, level: Pref.defaultLevelValue, password: password,
            deletions: Set(nodes.map(\.path)), sources: [], prefix: "", names: [:], excludeMacMetadata: true
        )
        let title = nodes.count == 1
            ? String(localized: "Deleting “\(nodes[0].name)”") : String(localized: "Deleting \(nodes.count) items")
        let message = nodes.count == 1
            ? String(localized: "Deleted “\(nodes[0].name)” from the archive")
            : String(localized: "Deleted \(nodes.count) items from the archive")
        runEdit(request, title: title, notice: message, select: []) { [weak self] in
            self?.runDeletion(nodes)
        }
    }

    private struct EditRequest: Sendable {
        var url: URL
        var format: OutputFormat
        var level: CompressionLevel
        var password: String?
        var deletions: Set<String>
        var sources: [URL]
        var prefix: String
        var names: [URL: String]
        var excludeMacMetadata: Bool
    }

    private func runEdit(
        _ request: EditRequest, title: String, notice message: String, select paths: Set<String>,
        retry: @escaping @MainActor () -> Void
    ) {
        job = Job(title: title)
        jobTask = Task { [weak self] in
            do {
                try await Self.performEdit(request) { progress in
                    Task { @MainActor in
                        self?.job?.fraction = progress.fraction
                        self?.job?.detail = progress.currentItem
                    }
                }
                guard let self else { return }
                self.previews.reset()
                try await self.reload(selecting: paths)
                self.job = nil
                self.showNotice(Notice(message: message, outputs: []))
            } catch {
                guard let self else { return }
                self.job = nil
                self.handle(error, retry: retry)
            }
        }
    }

    @concurrent
    private static func performEdit(_ request: EditRequest, progress: @escaping @Sendable (CompressionProgress) -> Void) async throws {
        let additions = ArchiveWriter.collect(
            request.sources, under: request.prefix, names: request.names, excludeMacMetadata: request.excludeMacMetadata
        )
        try ArchiveEditor.apply(
            ArchiveEdit(deletions: request.deletions, additions: additions),
            to: request.url, format: request.format, level: request.level, password: request.password, progress: progress
        )
    }

    /// Re-lists the archive in place after an edit, keeping the current folder.
    private func reload(selecting paths: Set<String>) async throws {
        let (info, newTree) = try await Self.read(url: url, password: password, includeMetadata: showsMacMetadata) { _ in }
        self.info = info
        apply(newTree)
        selection = Set(newTree.nodes.filter { paths.contains($0.path.precomposedStringWithCanonicalMapping) }.map(\.id))
    }

    private func ensureEditable() -> Bool {
        if let reason = editUnavailableReason {
            errorMessage = reason
            return false
        }
        return phase == .ready && job == nil
    }

    /// Rewriting decrypts every entry, so encrypted archives need the password first.
    private func withEditPassword(_ action: @escaping @MainActor () -> Void) {
        if info?.hasEncryptedEntries == true, password == nil {
            requestPassword(isRetry: false, then: action)
        } else {
            action()
        }
    }

    // MARK: Passwords & errors

    private func withPassword(for nodes: [ArchiveNode], _ action: @escaping @MainActor () -> Void) {
        if nodes.contains(where: \.isEncrypted), password == nil {
            requestPassword(isRetry: false, then: action)
        } else {
            action()
        }
    }

    private func requestPassword(isRetry: Bool, then action: @escaping @MainActor () -> Void) {
        passwordRequest = PasswordRequest(isRetry: isRetry, onSubmit: action)
    }

    func submitPassword(_ value: String) {
        guard let request = passwordRequest else { return }
        password = value
        passwordRequest = nil
        request.onSubmit()
    }

    func cancelPasswordRequest() {
        passwordRequest = nil
    }

    private func handle(_ error: Error, retry: @escaping @MainActor () -> Void) {
        switch error as? ArchiveError {
        case .cancelled:
            break
        case .passwordRequired, .wrongPassword:
            let wasWrong = password != nil
            password = nil
            requestPassword(isRetry: wasWrong, then: retry)
        default:
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Quick Look & drag

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        refreshQuickLook { panel.makeKeyAndOrderFront(nil) }
    }

    func selectionDidChange() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        refreshQuickLook { panel.reloadData() }
    }

    private func refreshQuickLook(then present: @escaping @MainActor () -> Void) {
        let nodes = selectedNodes.filter { !$0.isDirectory || isPackage($0) }
        guard !nodes.isEmpty else { return }
        withPassword(for: nodes) { [weak self] in
            guard let self else { return }
            Task {
                var urls: [URL] = []
                for node in nodes {
                    do {
                        urls.append(try await self.previews.file(for: node, password: self.password))
                    } catch {
                        self.handle(error) { self.refreshQuickLook(then: present) }
                        return
                    }
                }
                self.quickLookItems = urls
                present()
            }
        }
    }

    /// Finder asks for the file only when the drop happens, so nothing is extracted for cancelled drags.
    func itemProvider(for node: ArchiveNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        if let cached = previews.cachedFile(for: node) {
            provider.registerObject(cached as NSURL, visibility: .all)
            return provider
        }
        let type: UTType = node.isDirectory ? .folder : UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        let password = password
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { [weak self] completion in
            // Foundation calls the completion handler from any thread; it is safe to hand over.
            let reply = UncheckedSendable(value: completion)
            Task { @MainActor in
                guard let self else { return reply.value(nil, false, ArchiveError.cancelled) }
                do {
                    let url = try await self.previews.file(for: node, password: password)
                    reply.value(url, false, nil)
                } catch {
                    reply.value(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    func copyPath(_ nodes: [ArchiveNode]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nodes.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Lifecycle

    func close() {
        loadTask?.cancel()
        jobTask?.cancel()
        noticeTask?.cancel()
        previews.purge()
    }
}

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

extension ArchiveModel: BackgroundWork {
    var isBusy: Bool { job != nil }
    var busyTitle: String { job?.title ?? "" }

    func cancelAndWait() async {
        jobTask?.cancel()
        await jobTask?.value
    }
}
