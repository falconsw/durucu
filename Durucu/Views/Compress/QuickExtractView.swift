import SwiftUI

struct QuickExtractView: View {
    let model: QuickExtractModel
    @State private var password = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: FileIcons.icon(for: model.url))
                .resizable()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 10) {
                Text(model.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                content
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: 420, alignment: .topLeading)
        .frame(minHeight: 150)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .working:
            ProgressView(value: model.fraction)
            HStack {
                Text(model.currentItem.isEmpty ? String(localized: "Extracting…") : model.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .needsPassword(let isRetry):
            Text(isRetry ? String(localized: "Incorrect password. Try again.") : String(localized: "This archive is password protected."))
                .font(.callout)
                .foregroundStyle(isRetry ? .red : .secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit(password: password) }
                Button("Open") { model.submit(password: password) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { model.cancel() }
                    .keyboardShortcut(.defaultAction)
            }
        case .done:
            Label("Extracted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce)
        }
    }
}
