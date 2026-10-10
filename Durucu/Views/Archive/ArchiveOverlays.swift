import SwiftUI

/// Floating progress card while extracting, and the "done" banner afterwards.
struct ArchiveOverlays: View {
    @Bindable var model: ArchiveModel

    var body: some View {
        ZStack {
            if let job = model.job {
                JobCard(job: job) { model.cancelJob() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = model.notice {
                NoticeCard(notice: notice) { model.notice = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.job != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.notice)
    }
}

private struct JobCard: View {
    let job: ArchiveModel.Job
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.02, job.fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: job.fraction)
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.pulse)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(job.detail.isEmpty ? "Hazırlanıyor…" : job.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 260, alignment: .leading)

            Text(Format.percent(job.fraction))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: job.fraction))
                .frame(width: 44, alignment: .trailing)

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("İptal")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}

private struct NoticeCard: View {
    let notice: ArchiveModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: notice.id)
            Text(notice.message)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)
            if !notice.outputs.isEmpty {
                Button("Finder'da Göster") {
                    NSWorkspace.shared.activateFileViewerSelecting(notice.outputs)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 14, height: 14)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}

struct PasswordSheet: View {
    let archiveName: String
    let isRetry: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @State private var reveal = false
    @State private var shakes: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isRetry ? "lock.trianglebadge.exclamationmark.fill" : "lock.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background((isRetry ? Color.red : Color.accentColor).gradient, in: Circle())
                .symbolEffect(.bounce, value: shakes)

            VStack(spacing: 4) {
                Text(isRetry ? "Şifre yanlış" : "Şifre gerekli")
                    .font(.title2.weight(.bold))
                Text(isRetry ? "Tekrar dener misin?" : "“\(archiveName)” şifreli dosyalar içeriyor.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField("Şifre", text: $password)
                    } else {
                        SecureField("Şifre", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(reveal ? "Gizle" : "Göster")
            }
            .modifier(Shake(animatableData: shakes))

            HStack {
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Aç", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear {
            focused = true
            if isRetry { withAnimation(.default) { shakes += 1 } }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
    }
}
