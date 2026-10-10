import Quartz
import SwiftUI

/// Inline Quick Look, as in Finder's preview pane.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// How much of the original size compression saved.
struct SavingsBar: View {
    let savings: Double

    var body: some View {
        if savings < 0 {
            Text("—").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: max(3, proxy.size.width * savings))
                    }
                }
                .frame(width: 44, height: 5)
                Text(Format.percent(savings))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
    }

    private var color: Color {
        switch savings {
        case ..<0.1: .gray
        case ..<0.4: .teal
        default: .accentColor
        }
    }
}

struct SavingsRing: View {
    let savings: Double
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, savings))
                .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Format.percent(savings))
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .animation(.smooth, value: savings)
    }
}

struct FormatBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.6)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .gridColumnAlignment(.leading)
        }
    }
}

/// Horizontal shake used when a password is rejected.
struct Shake: GeometryEffect {
    var travel: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Animated dashed outline shown while files hover over a drop area.
struct DropHighlight: View {
    let isActive: Bool
    var cornerRadius: CGFloat = 22
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                Color.accentColor.opacity(isActive ? 0.9 : 0),
                style: StrokeStyle(lineWidth: 2, dash: [8, 6], dashPhase: phase)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = -28 }
            }
            .animation(.easeOut(duration: 0.2), value: isActive)
            .allowsHitTesting(false)
    }
}

extension EnvironmentValues {
    /// The AppKit window hosting this view, for sheets and panels.
    @Entry var window: NSWindow? = nil
}

extension View {
    /// Accepts file URLs dragged in from Finder.
    func fileDrop(isTargeted: Binding<Bool>, perform: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            perform(files)
            return true
        } isTargeted: { isTargeted.wrappedValue = $0 }
    }
}
