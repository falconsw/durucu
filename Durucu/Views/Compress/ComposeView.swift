import SwiftUI

struct ComposeView: View {
    @Bindable var model: ComposeModel
    let close: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            switch model.phase {
            case .editing:
                ComposeEditor(model: model, close: close)
                    .transition(.opacity)
            case .working:
                ComposeProgress(model: model)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            case .done(let outcome):
                ComposeDone(outcome: outcome, close: close)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't create the archive", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(message)
                } actions: {
                    Button("Go Back") { model.backToEditing() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: phaseKey)
        .frame(minWidth: 560, minHeight: 620)
    }

    private var phaseKey: Int {
        switch model.phase {
        case .editing: 0
        case .working: 1
        case .done: 2
        case .failed: 3
        }
    }
}

private struct ComposeEditor: View {
    @Bindable var model: ComposeModel
    let close: () -> Void
    @State private var isTargeted = false
    @State private var selection = Set<URL>()
    @Environment(\.window) private var window

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 16)

            sourceList
                .padding(.horizontal, 28)

            Form {
                Section {
                    LabeledContent("Name") {
                        HStack(spacing: 4) {
                            TextField("Name", text: Binding(get: { model.name }, set: { model.renameByUser($0) }))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Text(verbatim: ".\(model.format.fileExtension)")
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }
                    }
                    LabeledContent("Location") {
                        Button {
                            model.chooseDestination(window: window)
                        } label: {
                            HStack(spacing: 6) {
                                Image(nsImage: FileIcons.icon(for: model.destination))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(FileManager.default.displayName(atPath: model.destination.path))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help(model.destination.path)
                    }
                }

                Section {
                    Picker("Format", selection: $model.format) {
                        ForEach(OutputFormat.creatable) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(model.format.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Compression", selection: $model.level) {
                        ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle(isOn: $model.usesPassword) {
                        Text("Encrypt")
                        Text(model.format.supportsPassword
                            ? String(localized: "AES-256. A password is needed to open it.")
                            : String(localized: "Encryption is only available for ZIP."))
                    }
                    .disabled(!model.format.supportsPassword)
                    if model.usesPassword, model.format.supportsPassword {
                        SecureField("Password", text: $model.password)
                        SecureField("Confirm Password", text: $model.passwordConfirmation)
                        if let problem = model.passwordProblem, !model.passwordConfirmation.isEmpty || model.password.isEmpty {
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Toggle(isOn: $model.excludesMacMetadata) {
                        Text("Leave out macOS clutter")
                        Text("`.DS_Store` and `._` files look like junk on Windows.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .animation(.smooth, value: model.usesPassword)

            HStack {
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    model.start()
                } label: {
                    Label("Compress", systemImage: "shippingbox.fill")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New archive")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Group {
                    if model.sources.isEmpty {
                        Text("Add the files to put in the archive")
                    } else if model.isScanning {
                        Text("\(model.sources.count) items · calculating…")
                    } else {
                        Text("\(model.fileCount) files · \(Format.bytes(model.totalBytes))")
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            Button {
                addFiles()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.glass)
        }
    }

    private var sourceList: some View {
        ZStack {
            if model.sources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isTargeted)
                    Text("Drop files and folders here")
                        .font(.headline)
                    Button("Choose Files…", action: addFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.sources) { source in
                        SourceRow(source: source)
                            .tag(source.url)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
                                Button("Remove from List") { model.remove([source.url]) }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    model.remove(selection)
                    selection = []
                }
            }
        }
        .frame(height: 170)
        .glassEffect(.regular.tint(Color.accentColor.opacity(isTargeted ? 0.15 : 0)), in: .rect(cornerRadius: 18))
        .overlay(DropHighlight(isActive: isTargeted, cornerRadius: 18))
        .fileDrop(isTargeted: $isTargeted) { model.add($0) }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add")
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { model.add(panel.urls) }
        }
    }
}

private struct SourceRow: View {
    let source: ComposeModel.Source

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: source.url))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if let bytes = source.bytes {
                Text(Format.bytes(bytes))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ComposeProgress: View {
    let model: ComposeModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.01, model.progress.fraction))
                    .stroke(
                        AngularGradient(colors: [.orange, .pink, .orange], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: model.progress.fraction)
                VStack(spacing: 2) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.wiggle, options: .repeat(.continuous))
                    Text(Format.percent(model.progress.fraction))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: model.progress.fraction))
                }
            }
            .frame(width: 170, height: 170)

            VStack(spacing: 6) {
                Text("Compressing…")
                    .font(.title2.weight(.bold))
                Text(model.progress.currentItem.isEmpty ? model.outputFileName : model.progress.currentItem)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(stats)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Button("Cancel", role: .cancel) { model.cancel() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stats: String {
        var parts = ["\(Format.bytes(model.progress.bytesDone)) / \(Format.bytes(model.totalBytes))"]
        if model.bytesPerSecond > 0 { parts.append(String(localized: "\(Format.bytes(Int64(model.bytesPerSecond)))/s")) }
        if let remaining = model.remainingSeconds { parts.append(String(localized: "about \(Format.duration(remaining)) left")) }
        return parts.joined(separator: " · ")
    }
}

private struct ComposeDone: View {
    let outcome: ComposeModel.Outcome
    let close: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, value: appeared)

            VStack(spacing: 6) {
                Text("Archive ready")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(outcome.output.lastPathComponent)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 24) {
                stat(Format.bytes(outcome.originalBytes), "before")
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                stat(Format.bytes(outcome.archiveBytes), "after")
                if outcome.originalBytes > 0 {
                    let saved = max(0, 1 - Double(outcome.archiveBytes) / Double(outcome.originalBytes))
                    stat(Format.percent(saved), "smaller")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            Text("Took \(Format.duration(outcome.duration))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Open Archive") {
                    WindowManager.shared.openArchive(outcome.output)
                    close()
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outcome.output])
                    close()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
