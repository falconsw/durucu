import SwiftUI

struct HomeView: View {
    @State private var compressTargeted = false
    @State private var openTargeted = false
    @State private var isDefault = DefaultApps.isDefault(for: DefaultApps.zip)
    @State private var zipHandler = DefaultApps.handlerName(for: DefaultApps.zip)
    private var recents = RecentArchives.shared

    var body: some View {
        ZStack {
            HomeBackground()
            VStack(alignment: .leading, spacing: 26) {
                header
                GlassEffectContainer(spacing: 18) {
                    HStack(spacing: 18) {
                        ActionCard(
                            title: "Compress",
                            subtitle: "Drop files and folders to wrap them into one archive.",
                            systemImage: "shippingbox.fill",
                            hint: "or click to choose",
                            tint: .orange,
                            isTargeted: $compressTargeted
                        ) {
                            WindowManager.shared.chooseFilesToCompress()
                        } onDrop: { urls in
                            WindowManager.shared.showCompose(with: urls)
                        }
                        ActionCard(
                            title: "Open",
                            subtitle: "ZIP, 7Z, RAR, TAR… Look inside, extract what you need.",
                            systemImage: "archivebox.fill",
                            hint: "or click to choose",
                            tint: .pink,
                            isTargeted: $openTargeted
                        ) {
                            WindowManager.shared.chooseArchivesToOpen()
                        } onDrop: { urls in
                            WindowManager.shared.open(urls)
                        }
                    }
                }
                recentSection
                Spacer(minLength: 0)
                defaultAppBar
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 26)
        }
        .frame(width: 860, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDefaultState()
            recents.prune()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 68, height: 68)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Dürücü")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("Wrap up your files, open your archives.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Settings")
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recents.urls.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently opened")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(recents.urls.prefix(8), id: \.self) { url in
                            RecentChip(url: url)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var defaultAppBar: some View {
        HStack(spacing: 10) {
            Image(systemName: isDefault ? "checkmark.seal.fill" : "info.circle.fill")
                .foregroundStyle(isDefault ? Color.green : Color.accentColor)
                .font(.title3)
            if isDefault {
                Text("Finder opens ZIP files with Dürücü.")
            } else {
                Text("ZIP files currently open with **\(zipHandler)**.")
                Spacer()
                Button("Make Dürücü the Default") {
                    Task {
                        await DefaultApps.makeDefault()
                        refreshDefaultState()
                    }
                }
                .buttonStyle(.glassProminent)
            }
            if isDefault { Spacer() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func refreshDefaultState() {
        isDefault = DefaultApps.isDefault(for: DefaultApps.zip)
        zipHandler = DefaultApps.handlerName(for: DefaultApps.zip)
    }
}

private struct ActionCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let hint: LocalizedStringKey
    let tint: Color
    @Binding var isTargeted: Bool
    let action: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: tint.opacity(0.35), radius: 10, y: 6)
                    .symbolEffect(.bounce, value: isTargeted)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(isTargeted ? "Drop!" : hint, systemImage: isTargeted ? "arrow.down.circle.fill" : "hand.point.up.left")
                    .font(.caption)
                    .foregroundStyle(isTargeted ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(height: 226)
        .glassEffect(.regular.tint(tint.opacity(isTargeted ? 0.22 : 0.04)).interactive(), in: .rect(cornerRadius: 26))
        .overlay(DropHighlight(isActive: isTargeted, cornerRadius: 26))
        .scaleEffect(isTargeted ? 1.025 : isHovering ? 1.01 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isTargeted)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .fileDrop(isTargeted: $isTargeted, perform: onDrop)
    }
}

private struct RecentChip: View {
    let url: URL

    var body: some View {
        Button {
            WindowManager.shared.open([url])
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(for: url))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help(url.path)
    }
}

private struct HomeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.62, 0.42], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: colorScheme == .dark ? darkColors : lightColors
        )
        .ignoresSafeArea()
    }

    private var lightColors: [Color] {
        [
            Color(red: 1.00, green: 0.93, blue: 0.86), Color(red: 1.00, green: 0.96, blue: 0.92), Color(red: 1.00, green: 0.90, blue: 0.90),
            Color(red: 1.00, green: 0.89, blue: 0.80), Color(red: 0.99, green: 0.97, blue: 0.95), Color(red: 0.99, green: 0.88, blue: 0.91),
            Color(red: 1.00, green: 0.95, blue: 0.90), Color(red: 0.98, green: 0.92, blue: 0.94), Color(red: 0.97, green: 0.90, blue: 0.96),
        ]
    }

    private var darkColors: [Color] {
        [
            Color(red: 0.16, green: 0.09, blue: 0.07), Color(red: 0.11, green: 0.08, blue: 0.09), Color(red: 0.15, green: 0.07, blue: 0.11),
            Color(red: 0.20, green: 0.10, blue: 0.06), Color(red: 0.10, green: 0.09, blue: 0.10), Color(red: 0.17, green: 0.07, blue: 0.12),
            Color(red: 0.12, green: 0.08, blue: 0.07), Color(red: 0.10, green: 0.07, blue: 0.10), Color(red: 0.13, green: 0.06, blue: 0.13),
        ]
    }
}
