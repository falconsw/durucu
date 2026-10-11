import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// `Durucu --promo-video out.mp4 [--portrait]` renders a short promo frame by frame: a zip on
/// the desktop is double-clicked, Dürücü shows what's inside, three files are picked and
/// extracted, and a note is dropped into the archive. Sample data only; nothing is read or
/// written besides the video. The language follows `-appLanguage tr|en`.
@MainActor
enum PromoVideo {
    /// Where things go in one output shape. Points; `pixels` is the encoded size.
    struct Output {
        let canvas: CGSize
        let pixels: CGSize
        let fps: Int
        let bitRate: Int
        /// The archive window, and its sidebar (0 leaves the sidebar out).
        let window: CGRect
        let sidebarWidth: CGFloat
        /// Desktop icons: the archive, the note that gets added, the extracted folder.
        let zipIcon: CGPoint
        let notesIcon: CGPoint
        let folderIcon: CGPoint
        let iconSize: CGFloat
        let captionY: CGFloat
        let captionSize: CGFloat
        let cursorStart: CGPoint
        let menuTitles: Int
        let isCompact: Bool

        var scale: CGFloat { pixels.width / canvas.width }

        /// 1080p for X and YouTube.
        static let landscape = Output(
            canvas: CGSize(width: 1280, height: 720), pixels: CGSize(width: 1920, height: 1080),
            fps: 60, bitRate: 14_000_000,
            window: CGRect(x: 220, y: 50, width: 1020, height: 548), sidebarWidth: 220,
            zipIcon: CGPoint(x: 110, y: 150), notesIcon: CGPoint(x: 110, y: 290), folderIcon: CGPoint(x: 110, y: 430),
            iconSize: 64, captionY: 656, captionSize: 22,
            cursorStart: CGPoint(x: 640, y: 420), menuTitles: 6, isCompact: false
        )

        /// 1080×1920 for Instagram Reels and TikTok. Instagram draws its own controls over the
        /// top and the bottom fifth, so the story stays between them.
        static let portrait = Output(
            canvas: CGSize(width: 540, height: 960), pixels: CGSize(width: 1080, height: 1920),
            fps: 30, bitRate: 10_000_000,
            window: CGRect(x: 20, y: 276, width: 468, height: 466), sidebarWidth: 0,
            zipIcon: CGPoint(x: 100, y: 206), notesIcon: CGPoint(x: 250, y: 206), folderIcon: CGPoint(x: 400, y: 206),
            iconSize: 52, captionY: 132, captionSize: 20,
            cursorStart: CGPoint(x: 300, y: 560), menuTitles: 2, isCompact: true
        )
    }

    static func write(to path: String, output: Output = .landscape) async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)

        let copy = PromoCopy(language: AppLanguage.preferred)
        let scene = PromoScene(
            output: output,
            script: PromoScript(output: output, copy: copy),
            copy: copy,
            wallpaper: wallpaper(output),
            appIcon: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
            zipIcon: NSWorkspace.shared.icon(for: .zip),
            notesIcon: FileIcons.icon(forName: copy.notesName, isDirectory: false)
        )

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        do {
            try await encode(scene, to: url)
            print("wrote \(path) (\(Int(output.pixels.width))x\(Int(output.pixels.height)), \(String(format: "%.1f", PromoScript.duration)) s)")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: - Encoding

    private static func encode(_ scene: PromoScene, to url: URL) async throws {
        let output = scene.output
        let pixels = output.pixels
        let fps = output.fps
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixels.width),
            AVVideoHeightKey: Int(pixels.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: output.bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixels.width),
            kCVPixelBufferHeightKey as String: Int(pixels.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let renderer = ImageRenderer(content: PromoFrame(scene: scene, time: 0))
        renderer.proposedSize = ProposedViewSize(output.canvas)
        renderer.scale = output.scale
        let frames = Int((PromoScript.duration * Double(fps)).rounded(.up))
        for frame in 0..<frames {
            renderer.content = PromoFrame(scene: scene, time: Double(frame) / Double(fps))
            guard let image = renderer.cgImage else { continue }
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(2))
            }
            guard let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool) else { continue }
            _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            if frame % fps == 0 { print("frame \(frame)/\(frames)") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return buffer
    }

    /// The stock macOS wallpaper scaled once to the frame, so frames do not resample a 6K image each time.
    private static func wallpaper(_ output: Output) -> CGImage? {
        let pixels = output.pixels
        guard let source = NSImage(contentsOf: URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")),
              let context = CGContext(
                data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let size = source.size
        let fill = max(pixels.width / size.width, pixels.height / size.height)
        let drawn = CGSize(width: size.width * fill, height: size.height * fill)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: CGRect(
            x: (pixels.width - drawn.width) / 2, y: (pixels.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height
        ))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

// MARK: - Words

/// Every word in the video, in the language it is rendered in. The string catalog is not
/// used: it follows the language the process launched with, not `-appLanguage`.
private struct PromoCopy {
    let isTurkish: Bool
    let locale: Locale

    init(language: AppLanguage) {
        isTurkish = language == .turkish
        locale = Locale(identifier: isTurkish ? "tr_TR" : "en_US")
    }

    private func pick(_ english: String, _ turkish: String) -> String { isTurkish ? turkish : english }

    var archiveBase: String { pick("Design-Files", "Tasarım-Dosyaları") }
    var archiveName: String { archiveBase + ".zip" }
    var notesName: String { pick("Notes.txt", "Notlar.txt") }

    var captions: [String] {
        [
            pick("Double-click a zip…", "Bir zip'e çift tıkla…"),
            pick("…and see what's inside first.", "…önce içinde ne var, gör."),
            pick("Pick only what you need.", "Sadece lazım olanı seç."),
            pick("Extract just that. Nothing else spills out.", "Yalnızca onu çıkart. Gerisi ortalığa dökülmez."),
            pick("Add or remove files without unpacking.", "Açmadan dosya ekle ya da sil."),
        ]
    }

    var finderMenus: [String] {
        isTurkish ? ["Dosya", "Düzen", "Görüntü", "Git", "Pencere", "Yardım"] : ["File", "Edit", "View", "Go", "Window", "Help"]
    }

    var appMenus: [String] {
        isTurkish ? ["Dosya", "Düzen", "Görüntü", "Arşiv", "Pencere", "Yardım"] : ["File", "Edit", "View", "Archive", "Window", "Help"]
    }

    var clock: String { pick("Sun Oct 11  10:42", "Paz 11 Eki  10:42") }
    var folders: String { pick("Folders", "Klasörler") }
    var nameColumn: String { pick("Name", "Ad") }
    var search: String { pick("Search archive", "Arşivde ara") }
    var showInFinder: String { pick("Show in Finder", "Finder'da Göster") }
    var tagline: String { pick("Wrap up your files, open your archives.", "Dosyalarını dür, arşivlerini aç.") }

    func title(of column: WindowLayout.Column) -> String {
        switch column {
        case .size: pick("Size", "Boyut")
        case .packed: pick("Compressed", "Sıkıştırılmış")
        case .saved: pick("Saved", "Kazanç")
        case .modified: pick("Date Modified", "Değiştirilme")
        }
    }

    func extractLabel(hasSelection: Bool) -> String {
        hasSelection ? pick("Extract Selected", "Seçilenleri Çıkart") : pick("Extract All", "Tümünü Çıkart")
    }

    func files(_ count: Int) -> String { isTurkish ? "\(count) dosya" : "\(count) files" }
    func items(_ count: Int) -> String { isTurkish ? "\(count) öğe" : "\(count) items" }
    func subtitle(_ totals: PromoTotals) -> String { "ZIP · \(files(totals.files)) · \(bytes(totals.archive))" }
    func saved(_ savings: Double) -> String { isTurkish ? "\(percent(savings)) kazanç" : "\(percent(savings)) saved" }

    func selected(_ count: Int, of total: Int, bytes size: Int64) -> String {
        isTurkish ? "\(count) / \(total) öğe seçildi · \(bytes(size))" : "\(count) of \(total) selected · \(bytes(size))"
    }

    func totals(_ totals: PromoTotals) -> String {
        let unpacked = isTurkish ? "açılmış \(bytes(totals.unpacked))" : "\(bytes(totals.unpacked)) unpacked"
        let archive = isTurkish ? "arşiv \(bytes(totals.archive))" : "\(bytes(totals.archive)) archive"
        return [files(totals.files), unpacked, archive, saved(totals.savings)].joined(separator: " · ")
    }

    func summary(_ totals: PromoTotals) -> String {
        isTurkish ? "\(totals.files) dosya · \(totals.folders) klasör" : "\(totals.files) files · \(totals.folders) folders"
    }

    func extracting(_ count: Int) -> String { isTurkish ? "\(count) öğe çıkartılıyor" : "Extracting \(count) items" }
    func adding(_ name: String) -> String { isTurkish ? "“\(name)” ekleniyor" : "Adding “\(name)”" }
    func extracted(_ name: String) -> String { isTurkish ? "“\(name)” çıkartıldı" : "Extracted “\(name)”" }
    func added(_ name: String) -> String { isTurkish ? "“\(name)” eklendi" : "Added “\(name)”" }
    func addTo(_ name: String) -> String { isTurkish ? "“\(name)” içine ekle" : "Add to “\(name)”" }

    func bytes(_ value: Int64) -> String { value.formatted(.byteCount(style: .file).locale(locale)) }
    func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0)).locale(locale)) }
    func date(_ value: Date) -> String { value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)) }
}

// MARK: - Sample data

/// A typical design hand-off. Plausible, not read from this Mac.
private struct SampleEntry {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let packed: Int64
    /// Files inside a folder; 1 for a file.
    let files: Int
    let modified: Date

    var savings: Double { size > 0 ? max(0, 1 - Double(packed) / Double(size)) : -1 }

    static func all(_ copy: PromoCopy) -> [SampleEntry] {
        let tr = copy.isTurkish
        func day(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .now
        }
        return [
            SampleEntry(id: "brand", name: tr ? "Marka" : "Brand", isFolder: true,
                        size: 9_840_000, packed: 7_120_000, files: 6, modified: day(8, 17, 5)),
            SampleEntry(id: "fonts", name: tr ? "Fontlar" : "Fonts", isFolder: true,
                        size: 4_210_000, packed: 1_930_000, files: 4, modified: day(2, 11, 20)),
            SampleEntry(id: "photos", name: tr ? "Fotoğraflar" : "Photos", isFolder: true,
                        size: 21_600_000, packed: 21_080_000, files: 18, modified: day(9, 14, 48)),
            SampleEntry(id: "screens", name: tr ? "Ekranlar" : "Screens", isFolder: true,
                        size: 6_320_000, packed: 5_610_000, files: 9, modified: day(10, 9, 12)),
            SampleEntry(id: "brief", name: tr ? "Brif.pdf" : "Brief.pdf", isFolder: false,
                        size: 3_410_000, packed: 3_080_000, files: 1, modified: day(7, 16, 30)),
            SampleEntry(id: "budget", name: tr ? "Bütçe-2026.xlsx" : "Budget-2026.xlsx", isFolder: false,
                        size: 2_140_000, packed: 612_000, files: 1, modified: day(6, 10, 2)),
            SampleEntry(id: "logo", name: "logo.svg", isFolder: false,
                        size: 84_200, packed: 21_400, files: 1, modified: day(8, 12, 44)),
            SampleEntry(id: "deck", name: tr ? "Sunum.key" : "Presentation.key", isFolder: false,
                        size: 18_600_000, packed: 17_900_000, files: 1, modified: day(10, 18, 21)),
            SampleEntry(id: "readme", name: tr ? "BENİOKU.md" : "README.md", isFolder: false,
                        size: 12_400, packed: 4_100, files: 1, modified: day(1, 9, 0)),
            SampleEntry(id: PromoScript.notesID, name: copy.notesName, isFolder: false,
                        size: 6_200, packed: 2_300, files: 1, modified: day(11, 10, 41)),
        ]
    }

    /// Folders first, then files, each by name: the order the archive window uses.
    static func sorted(_ entries: [SampleEntry]) -> [SampleEntry] {
        let byName = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return byName.filter(\.isFolder) + byName.filter { !$0.isFolder }
    }
}

private struct PromoTotals {
    let items: Int
    let files: Int
    let folders: Int
    let unpacked: Int64
    let packed: Int64
    let archive: Int64

    var savings: Double { unpacked > 0 ? max(0, 1 - Double(packed) / Double(unpacked)) : 0 }
}

// MARK: - Timeline

private func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
private func progress(_ time: Double, from start: Double, over duration: Double) -> Double {
    clamp01((time - start) / duration)
}
private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
}
private func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

/// When everything happens, worked out once before rendering. Seconds.
private struct PromoScript {
    static let notesID = "notes"
    /// Picked in this order, top to bottom.
    static let picks = ["brief", "budget", "logo"]

    static let captionTimes: [Double] = [0.2, 1.75, 2.9, 5.75, 7.9]
    static let zipSelected = 1.1
    static let windowOpen = 1.4
    static let pickTimes: [Double] = [3.05, 3.9, 4.6]
    static let commandKey = (start: 3.4, end: 4.85)
    static let extractClick = 5.8
    static let clicks: [Double] = [1.1, 1.26] + pickTimes + [extractClick]
    static let extractJob = (start: 5.9, end: 7.3)
    static let extractedAt = 7.35
    static let extractNotice = (start: 7.4, end: 9.0)
    static let grab = 8.8
    static let release = 10.1
    static let addJob = (start: 10.2, end: 10.95)
    static let inserted = 10.95
    static let addNotice = (start: 11.0, end: 12.9)
    static let endCardAt = 13.2
    static let duration = 16.4

    struct Move {
        let start: Double
        let end: Double
        let to: CGPoint
    }

    struct Job {
        let title: String
        let detail: String
        let fraction: Double
        let percent: String
        let shown: Double
    }

    struct Notice {
        let message: String
        let button: String?
        let shown: Double
    }

    let layout: WindowLayout
    let entries: [SampleEntry]
    /// The table before and after the note is added.
    let initialRows: [SampleEntry]
    let finalRows: [SampleEntry]
    /// The table area in canvas coordinates: where a drop lands.
    let dropArea: CGRect
    private let start: CGPoint
    private let moves: [Move]

    init(output: PromoVideo.Output, copy: PromoCopy) {
        let layout = WindowLayout(output: output)
        let window = output.window
        let entries = SampleEntry.all(copy)
        let finalRows = SampleEntry.sorted(entries)
        let initialRows = finalRows.filter { $0.id != Self.notesID }
        let dropArea = layout.detailFrame.offsetBy(dx: window.minX, dy: window.minY)
        func row(_ id: String) -> CGPoint {
            let index = initialRows.firstIndex { $0.id == id } ?? 0
            return CGPoint(x: window.minX + layout.detailX + 90, y: window.minY + layout.rowCenterY(Double(index)))
        }
        let button = layout.extractButton.offsetBy(dx: window.minX, dy: window.minY)
        let drop = CGPoint(x: dropArea.midX + 20, y: dropArea.midY + 10)

        self.layout = layout
        self.entries = entries
        self.finalRows = finalRows
        self.initialRows = initialRows
        self.dropArea = dropArea
        start = output.cursorStart
        moves = [
            Move(start: 0.25, end: 1.0, to: output.zipIcon),
            Move(start: 2.3, end: 2.95, to: row(Self.picks[0])),
            Move(start: 3.35, end: 3.8, to: row(Self.picks[1])),
            Move(start: 4.1, end: 4.5, to: row(Self.picks[2])),
            Move(start: 4.95, end: 5.7, to: CGPoint(x: button.midX, y: button.midY)),
            Move(start: 7.9, end: 8.7, to: output.notesIcon),
            Move(start: 8.95, end: 10.0, to: drop),
            Move(start: 11.3, end: 12.1, to: CGPoint(x: drop.x + 90, y: drop.y - 40)),
        ]
    }

    func cursor(at time: Double) -> CGPoint {
        var point = start
        for move in moves {
            guard time > move.start else { break }
            point = mix(point, move.to, easeInOut(progress(time, from: move.start, over: move.end - move.start)))
            if time < move.end { break }
        }
        return point
    }

    func isPressed(at time: Double) -> Bool {
        Self.clicks.contains { abs(time - $0) < 0.07 }
    }

    func isDragging(at time: Double) -> Bool {
        time >= Self.grab && time < Self.release
    }

    /// The dashed "Add to" outline, while the dragged note is over the table.
    func dropHighlight(at time: Double) -> Double {
        guard time >= Self.grab, time < Self.release + 0.2 else { return 0 }
        guard dropArea.contains(cursor(at: min(time, Self.release))) else { return 0 }
        return 1 - progress(time, from: Self.release, over: 0.2)
    }

    func opening(at time: Double) -> Double {
        easeOut(progress(time, from: Self.windowOpen, over: 0.5))
    }

    func selection(at time: Double) -> Set<String> {
        // Adding reloads the archive with the new file selected.
        if time >= Self.inserted { return [Self.notesID] }
        var ids = Set<String>()
        for (id, click) in zip(Self.picks, Self.pickTimes) where time >= click {
            ids.insert(id)
        }
        return ids
    }

    func insertion(at time: Double) -> Double {
        easeInOut(progress(time, from: Self.inserted, over: 0.3))
    }

    /// Where a row sits, counted in rows from the top of the table; nil before it exists.
    func slot(of entry: SampleEntry, at time: Double) -> Double? {
        guard let final = finalRows.firstIndex(where: { $0.id == entry.id }) else { return nil }
        guard let initial = initialRows.firstIndex(where: { $0.id == entry.id }) else {
            return time >= Self.inserted ? Double(final) : nil
        }
        return Double(initial) + Double(final - initial) * insertion(at: time)
    }

    func totals(at time: Double) -> PromoTotals {
        let items = time >= Self.inserted ? finalRows : initialRows
        let files = items.reduce(0) { $0 + $1.files }
        let packed = items.reduce(Int64(0)) { $0 + $1.packed }
        return PromoTotals(
            items: items.count, files: files, folders: items.filter(\.isFolder).count,
            unpacked: items.reduce(Int64(0)) { $0 + $1.size }, packed: packed,
            // Local and central directory headers.
            archive: packed + Int64(files) * 120
        )
    }

    func caption(at time: Double) -> (index: Int, opacity: Double)? {
        guard let index = Self.captionTimes.lastIndex(where: { $0 <= time }) else { return nil }
        let next = index + 1 < Self.captionTimes.count ? Self.captionTimes[index + 1] : Self.endCardAt
        let opacity = progress(time, from: Self.captionTimes[index], over: 0.3) * (1 - progress(time, from: next - 0.25, over: 0.25))
        return (index, opacity)
    }

    private static func shown(_ time: Double, _ span: (start: Double, end: Double)) -> Double {
        progress(time, from: span.start, over: 0.3) * (1 - progress(time, from: span.end, over: 0.25))
    }

    func job(at time: Double, copy: PromoCopy) -> Job? {
        let extracting = Self.shown(time, Self.extractJob)
        if extracting > 0 {
            let names = Self.picks.compactMap { id in entries.first { $0.id == id }?.name }
            let span = Self.extractJob
            let fraction = easeInOut(progress(time, from: span.start + 0.2, over: span.end - span.start - 0.35))
            let current = names[min(names.count - 1, Int(fraction * Double(names.count)))]
            return Job(
                title: copy.extracting(names.count), detail: current, fraction: fraction,
                percent: copy.percent(fraction), shown: extracting
            )
        }
        let adding = Self.shown(time, Self.addJob)
        if adding > 0 {
            let span = Self.addJob
            let fraction = easeInOut(progress(time, from: span.start + 0.15, over: span.end - span.start - 0.3))
            return Job(
                title: copy.adding(copy.notesName), detail: copy.notesName, fraction: fraction,
                percent: copy.percent(fraction), shown: adding
            )
        }
        return nil
    }

    func notice(at time: Double, copy: PromoCopy) -> Notice? {
        let extracted = Self.shown(time, Self.extractNotice)
        if extracted > 0 {
            // A smart folder: several items land in one folder named after the archive.
            return Notice(message: copy.extracted(copy.archiveBase), button: copy.showInFinder, shown: extracted)
        }
        let added = Self.shown(time, Self.addNotice)
        if added > 0 {
            return Notice(message: copy.added(copy.notesName), button: nil, shown: added)
        }
        return nil
    }
}

/// The archive window's insides, in window coordinates.
private struct WindowLayout {
    static let toolbarHeight: CGFloat = 52
    static let pathBarHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 28
    static let statusHeight: CGFloat = 28
    static let inset: CGFloat = 14

    enum Column {
        case size, packed, saved, modified

        var width: CGFloat {
            switch self {
            case .size: 80
            case .packed: 100
            case .saved: 104
            case .modified: 150
            }
        }

        var isTrailing: Bool { self == .size || self == .packed }
    }

    let size: CGSize
    let sidebarWidth: CGFloat
    let isCompact: Bool

    init(output: PromoVideo.Output) {
        size = output.window.size
        sidebarWidth = output.sidebarWidth
        isCompact = output.isCompact
    }

    var detailX: CGFloat { sidebarWidth > 0 ? sidebarWidth + 8 : 0 }
    var detailWidth: CGFloat { size.width - detailX }
    var detailFrame: CGRect {
        CGRect(x: detailX, y: Self.toolbarHeight, width: detailWidth, height: size.height - Self.toolbarHeight)
    }
    var rowsTop: CGFloat { Self.toolbarHeight + Self.pathBarHeight + Self.headerHeight }

    func rowCenterY(_ slot: Double) -> CGFloat {
        rowsTop + Self.rowHeight * (CGFloat(slot) + 0.5)
    }

    var columns: [Column] { isCompact ? [.size, .saved] : [.size, .packed, .saved, .modified] }
    var nameWidth: CGFloat { detailWidth - 2 * Self.inset - columns.reduce(CGFloat(0)) { $0 + $1.width } }

    // Toolbar, right to left. The compact window keeps only the Extract button.
    var searchField: CGRect? {
        isCompact ? nil : CGRect(x: size.width - 12 - 150, y: 10, width: 150, height: 32)
    }
    var extractButton: CGRect {
        let width: CGFloat = isCompact ? 176 : 184
        let right = searchField.map { $0.minX - 10 } ?? size.width - 12
        return CGRect(x: right - width, y: 10, width: width, height: 32)
    }
    var quickLookButton: CGRect? {
        isCompact ? nil : CGRect(x: extractButton.minX - 10 - 32, y: 10, width: 32, height: 32)
    }
    var editButtons: CGRect? {
        quickLookButton.map { CGRect(x: $0.minX - 10 - 76, y: 10, width: 76, height: 32) }
    }
    var navigationButtons: CGRect? {
        isCompact ? nil : CGRect(x: detailX + 10, y: 10, width: 102, height: 32)
    }
    var titleFrame: CGRect {
        let left = navigationButtons.map { $0.maxX + 14 } ?? 84
        let right = (editButtons ?? extractButton).minX - 10
        return CGRect(x: left, y: 0, width: right - left, height: Self.toolbarHeight)
    }
}

// MARK: - Frame

private struct PromoScene {
    let output: PromoVideo.Output
    let script: PromoScript
    let copy: PromoCopy
    let wallpaper: CGImage?
    let appIcon: NSImage
    let zipIcon: NSImage
    let notesIcon: NSImage
}

/// The app's accent color (AccentColor, dark appearance).
private let accent = Color(red: 1, green: 124 / 255, blue: 82 / 255)

private extension View {
    /// Toolbar glass, drawn flat: materials do not render offscreen.
    func chrome<S: InsettableShape>(_ shape: S, fill: Color = Color(white: 0.2)) -> some View {
        background(shape.fill(fill))
            .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

/// One frame of the video at `time` seconds.
private struct PromoFrame: View {
    let scene: PromoScene
    let time: Double

    private var output: PromoVideo.Output { scene.output }
    private var script: PromoScript { scene.script }
    private var copy: PromoCopy { scene.copy }

    var body: some View {
        let cursor = script.cursor(at: time)
        let opening = script.opening(at: time)
        ZStack(alignment: .topLeading) {
            wallpaper
            desktop

            if opening > 0 {
                PromoWindow(scene: scene, time: time)
                    .frame(width: output.window.width, height: output.window.height)
                    .scaleEffect(0.12 + 0.88 * opening, anchor: openingAnchor)
                    .opacity(min(1, opening * 2.5))
                    .offset(x: output.window.minX, y: output.window.minY)
            }

            ghost(at: cursor)
            menuBar
            caption
            pointer(at: cursor)
            endCard
        }
        .frame(width: output.canvas.width, height: output.canvas.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// The window grows out of the zip's icon.
    private var openingAnchor: UnitPoint {
        let window = output.window
        return UnitPoint(x: (output.zipIcon.x - window.minX) / window.width, y: (output.zipIcon.y - window.minY) / window.height)
    }

    // MARK: Desktop

    @ViewBuilder
    private var wallpaper: some View {
        if let image = scene.wallpaper {
            Image(decorative: image, scale: output.scale)
                .resizable()
                .frame(width: output.canvas.width, height: output.canvas.height)
        } else {
            LinearGradient(colors: [.indigo, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: output.canvas.width, height: output.canvas.height)
        }
    }

    private var desktop: some View {
        let size = output.iconSize
        let zipSelected = time >= PromoScript.zipSelected && time < PromoScript.grab
        let folder = progress(time, from: PromoScript.extractedAt, over: 0.45)
        return ZStack(alignment: .topLeading) {
            DesktopIcon(image: scene.zipIcon, name: copy.archiveName, size: size, isSelected: zipSelected)
                .position(iconCenter(output.zipIcon))
            DesktopIcon(image: scene.notesIcon, name: copy.notesName, size: size, isSelected: time >= PromoScript.grab)
                .opacity(script.isDragging(at: time) ? 0.5 : 1)
                .position(iconCenter(output.notesIcon))
            if folder > 0 {
                DesktopIcon(image: FileIcons.folder, name: copy.archiveBase, size: size, isSelected: false)
                    .scaleEffect(max(0.01, easeOutBack(folder)))
                    .opacity(min(1, folder * 3))
                    .position(iconCenter(output.folderIcon))
            }
        }
    }

    /// `DesktopIcon` puts its label under the icon; this moves the icon itself onto `point`.
    private func iconCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y + DesktopIcon.labelSpace / 2)
    }

    /// Finder's drag image: the note, see-through, under the pointer.
    @ViewBuilder
    private func ghost(at cursor: CGPoint) -> some View {
        if time >= PromoScript.grab && time < PromoScript.release + 0.2 {
            let lift = progress(time, from: PromoScript.grab, over: 0.15)
            let gone = progress(time, from: PromoScript.release, over: 0.2)
            DesktopIcon(image: scene.notesIcon, name: copy.notesName, size: output.iconSize, isSelected: true)
                .scaleEffect(1 - 0.5 * gone)
                .opacity(0.75 * lift * (1 - gone))
                .position(iconCenter(cursor))
        }
    }

    private var menuBar: some View {
        let isDurucu = time >= PromoScript.windowOpen
        let menus = (isDurucu ? copy.appMenus : copy.finderMenus).prefix(output.menuTitles)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(width: output.canvas.width, height: 24)

            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text(verbatim: isDurucu ? "Dürücü" : "Finder").font(.system(size: 13, weight: .bold))
                ForEach(Array(menus), id: \.self) { Text(verbatim: $0).font(.system(size: 13)) }
            }
            .foregroundStyle(.white)
            .frame(height: 24)
            .padding(.leading, 18)

            HStack(spacing: 16) {
                Image(systemName: "wifi")
                if !output.isCompact {
                    Image(systemName: "magnifyingglass")
                    Image(systemName: "switch.2")
                }
                Text(verbatim: output.isCompact ? "10:42" : copy.clock)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: output.canvas.width - 18, height: 24, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var caption: some View {
        if let line = script.caption(at: time), line.opacity > 0 {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            Text(verbatim: copy.captions[line.index])
                .font(.system(size: output.captionSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(shape.fill(Color.black.opacity(0.55)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .frame(maxWidth: output.canvas.width - 48)
                .offset(y: 8 * (1 - line.opacity))
                .opacity(line.opacity)
                .position(x: output.canvas.width / 2, y: output.captionY)
        }
    }

    // MARK: Pointer

    @ViewBuilder
    private func pointer(at point: CGPoint) -> some View {
        let visible = 1 - progress(time, from: PromoScript.endCardAt - 0.2, over: 0.3)
        if visible > 0 {
            let image = NSCursor.arrow.image
            let hotSpot = NSCursor.arrow.hotSpot
            let command = progress(time, from: PromoScript.commandKey.start, over: 0.15)
                * (1 - progress(time, from: PromoScript.commandKey.end, over: 0.15))
            ZStack(alignment: .topLeading) {
                ForEach(PromoScript.clicks, id: \.self) { click in
                    ripple(at: script.cursor(at: click), from: click)
                }
                Image(nsImage: image)
                    .scaleEffect(
                        script.isPressed(at: time) ? 0.85 : 1,
                        anchor: UnitPoint(x: hotSpot.x / image.size.width, y: hotSpot.y / image.size.height)
                    )
                    .position(x: point.x - hotSpot.x + image.size.width / 2, y: point.y - hotSpot.y + image.size.height / 2)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                if script.isDragging(at: time) && script.dropArea.contains(point) {
                    // Finder's green "copy" badge.
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.green))
                        .position(x: point.x + 16, y: point.y + 24)
                }
                if command > 0 {
                    // ⌘ held for the second and third pick.
                    Text(verbatim: "⌘")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.94)))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .scaleEffect(0.8 + 0.2 * command)
                        .opacity(command)
                        .position(x: point.x + 30, y: point.y + 34)
                }
            }
            .opacity(visible)
        }
    }

    @ViewBuilder
    private func ripple(at point: CGPoint, from start: Double) -> some View {
        let t = progress(time, from: start, over: 0.4)
        if t > 0 && t < 1 {
            Circle()
                .stroke(Color.white.opacity(0.7 * (1 - t)), lineWidth: 2)
                .frame(width: 10 + 40 * t, height: 10 + 40 * t)
                .position(point)
        }
    }

    // MARK: Closing card

    @ViewBuilder
    private var endCard: some View {
        let shown = easeInOut(progress(time, from: PromoScript.endCardAt, over: 0.6))
        if shown > 0 {
            let compact = output.isCompact
            ZStack {
                Color.black.opacity(0.72 * shown)
                VStack(spacing: 18) {
                    Image(nsImage: scene.appIcon)
                        .resizable()
                        .frame(width: 132, height: 132)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                    Text(verbatim: "Dürücü")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                    Text(verbatim: copy.tagline)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Text(verbatim: "brew install --cask falconsw/tap/durucu")
                        .font(.system(size: compact ? 14 : 19, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        .padding(.top, 6)
                    Text(verbatim: "github.com/falconsw/durucu")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .scaleEffect(0.94 + 0.06 * shown)
                .opacity(shown)
            }
            .frame(width: output.canvas.width, height: output.canvas.height)
        }
    }
}

/// A Finder desktop icon with its name underneath.
private struct DesktopIcon: View {
    /// Height kept under the icon for the name.
    static let labelSpace: CGFloat = 40

    let image: NSImage
    let name: String
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
                .padding(4)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.2))
                    }
                }
            Text(verbatim: name)
                .font(.system(size: size < 60 ? 11 : 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(red: 0.05, green: 0.4, blue: 0.9))
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0 : 0.7), radius: 2, y: 1)
        }
        .frame(width: size + 64, height: size + 8 + Self.labelSpace, alignment: .top)
    }
}

// MARK: - Window

/// The archive window, drawn by hand: tables, sidebars and glass do not render offscreen.
/// It follows `ArchiveWindowView` piece by piece.
private struct PromoWindow: View {
    let scene: PromoScene
    let time: Double

    private var layout: WindowLayout { scene.script.layout }
    private var script: PromoScript { scene.script }
    private var copy: PromoCopy { scene.copy }
    private var selection: Set<String> { script.selection(at: time) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            Color(white: 0.115)
            if layout.sidebarWidth > 0 {
                sidebar
            }
            trafficLights
            toolbar
            pathBar
            header
            rows
            statusBar
            dropOverlay
            overlays
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
            Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
        }
        .offset(x: 20, y: 20)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let width = layout.sidebarWidth
        let height = layout.size.height - 16
        let folders = script.finalRows.filter(\.isFolder)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill(Color(white: 0.165))
            shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            Text(verbatim: copy.folders)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(x: 16, y: 50)
            sidebarRow(icon: "archivebox.fill", tint: accent, name: copy.archiveName, isRoot: true, y: 68)
            ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                sidebarRow(icon: "folder.fill", tint: .secondary, name: folder.name, isRoot: false, y: 68 + CGFloat(index + 1) * 28)
            }
            summaryCard
                .frame(width: width - 20)
                .offset(x: 10, y: height - 10 - 74)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .offset(x: 8, y: 8)
    }

    private func sidebarRow(icon: String, tint: Color, name: String, isRoot: Bool, y: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .opacity(isRoot ? 1 : 0)
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(verbatim: name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, isRoot ? 8 : 24)
        .padding(.trailing, 8)
        .frame(width: layout.sidebarWidth - 16, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(isRoot ? 0.1 : 0)))
        .offset(x: 8, y: y)
    }

    /// Totals for the whole archive at the bottom of the sidebar.
    private var summaryCard: some View {
        let totals = script.totals(at: time)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return HStack(spacing: 12) {
            PromoRing(savings: totals.savings, label: copy.percent(totals.savings))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "ZIP")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.14), in: Capsule())
                Text(verbatim: copy.summary(totals))
                    .font(.system(size: 11))
                Text(verbatim: "\(copy.bytes(totals.unpacked)) → \(copy.bytes(totals.archive))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(shape.fill(Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let hasSelection = !selection.isEmpty
        return ZStack(alignment: .topLeading) {
            if let frame = layout.navigationButtons {
                // Nothing to go back to at the archive's root.
                HStack(spacing: 0) {
                    toolbarIcon("chevron.left", enabled: false)
                    toolbarIcon("chevron.right", enabled: false)
                    toolbarIcon("arrow.turn.left.up", enabled: false)
                }
                .frame(width: frame.width, height: frame.height)
                .chrome(Capsule())
                .offset(x: frame.minX, y: frame.minY)
            }
            titleBlock
            if let frame = layout.editButtons {
                HStack(spacing: 0) {
                    toolbarIcon("plus", enabled: true)
                    toolbarIcon("trash", enabled: hasSelection)
                }
                .frame(width: frame.width, height: frame.height)
                .chrome(Capsule())
                .offset(x: frame.minX, y: frame.minY)
            }
            if let frame = layout.quickLookButton {
                toolbarIcon("eye", enabled: hasSelection)
                    .frame(width: frame.width, height: frame.height)
                    .chrome(Circle())
                    .offset(x: frame.minX, y: frame.minY)
            }
            extractButton(hasSelection: hasSelection)
            if let frame = layout.searchField {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text(verbatim: copy.search)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .frame(width: frame.width, height: frame.height)
                .chrome(Capsule())
                .offset(x: frame.minX, y: frame.minY)
            }
        }
    }

    private func toolbarIcon(_ name: String, enabled: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleBlock: some View {
        let frame = layout.titleFrame
        return VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: copy.archiveName)
                .font(.system(size: 13.5, weight: .bold))
            Text(verbatim: copy.subtitle(script.totals(at: time)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func extractButton(hasSelection: Bool) -> some View {
        let frame = layout.extractButton
        let pressed = abs(time - PromoScript.extractClick) < 0.09
        return HStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: copy.extractLabel(hasSelection: hasSelection))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(width: frame.width, height: frame.height)
        .background(Capsule().fill(Color.white.opacity(pressed ? 0.16 : 0)))
        .chrome(Capsule())
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: Table

    private var pathBar: some View {
        HStack(spacing: 5) {
            Image(nsImage: scene.zipIcon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(verbatim: copy.archiveName)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .frame(width: layout.detailWidth, height: WindowLayout.pathBarHeight)
        .offset(x: layout.detailX, y: WindowLayout.toolbarHeight)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: copy.nameColumn)
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                Spacer(minLength: 0)
            }
            .frame(width: layout.nameWidth)
            ForEach(layout.columns, id: \.self) { column in
                Text(verbatim: copy.title(of: column))
                    .lineLimit(1)
                    .frame(width: column.width - 12, alignment: column.isTrailing ? .trailing : .leading)
                    .padding(.horizontal, 6)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, WindowLayout.inset)
        .frame(width: layout.detailWidth, height: WindowLayout.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 10)
        }
        .offset(x: layout.detailX, y: WindowLayout.toolbarHeight + WindowLayout.pathBarHeight)
    }

    private var rows: some View {
        let selection = self.selection
        let insertion = script.insertion(at: time)
        return ZStack(alignment: .topLeading) {
            ForEach(script.finalRows, id: \.id) { entry in
                if let slot = script.slot(of: entry, at: time) {
                    PromoRow(entry: entry, layout: layout, copy: copy, isSelected: selection.contains(entry.id))
                        .opacity(entry.id == PromoScript.notesID ? insertion : 1)
                        .offset(x: layout.detailX, y: layout.rowsTop + WindowLayout.rowHeight * CGFloat(slot))
                }
            }
        }
    }

    private var statusBar: some View {
        let totals = script.totals(at: time)
        let selected = script.finalRows.filter { selection.contains($0.id) }
        let leading = selected.isEmpty
            ? copy.items(totals.items)
            : copy.selected(selected.count, of: totals.items, bytes: selected.reduce(Int64(0)) { $0 + $1.size })
        let trailing = layout.isCompact ? copy.saved(totals.savings) : copy.totals(totals)
        return HStack(spacing: 8) {
            Text(verbatim: leading)
            Spacer(minLength: 0)
            Text(verbatim: trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(width: layout.detailWidth, height: WindowLayout.statusHeight)
        .offset(x: layout.detailX, y: layout.size.height - WindowLayout.statusHeight)
    }

    // MARK: Overlays

    @ViewBuilder
    private var dropOverlay: some View {
        let shown = script.dropHighlight(at: time)
        if shown > 0 {
            let frame = layout.detailFrame.insetBy(dx: 10, dy: 10)
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            let phase = CGFloat(-28 * (time / 1.2).truncatingRemainder(dividingBy: 1))
            ZStack {
                shape.fill(accent.opacity(0.08))
                shape.strokeBorder(accent.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6], dashPhase: phase))
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text(verbatim: copy.addTo(copy.archiveName))
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(accent.opacity(0.25)))
                .chrome(Capsule(), fill: Color(white: 0.17))
            }
            .frame(width: frame.width, height: frame.height)
            .opacity(shown)
            .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// The progress card while working and the "done" card after, as in `ArchiveOverlays`.
    private var overlays: some View {
        let box = CGRect(x: layout.detailX, y: layout.size.height - 40 - 120, width: layout.detailWidth, height: 120)
        return ZStack(alignment: .bottom) {
            if let job = script.job(at: time, copy: copy) {
                PromoJobCard(job: job, isCompact: layout.isCompact)
                    .offset(y: 24 * (1 - job.shown))
                    .opacity(job.shown)
            }
            if let notice = script.notice(at: time, copy: copy) {
                PromoNoticeCard(notice: notice)
                    .offset(y: 24 * (1 - notice.shown))
                    .opacity(notice.shown)
            }
        }
        .frame(width: box.width, height: box.height, alignment: .bottom)
        .offset(x: box.minX, y: box.minY)
    }
}

private struct PromoRow: View {
    let entry: SampleEntry
    let layout: WindowLayout
    let copy: PromoCopy
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: FileIcons.icon(forName: entry.name, isDirectory: entry.isFolder))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(verbatim: entry.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(width: layout.nameWidth)
            ForEach(layout.columns, id: \.self) { column in
                cell(column)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: column.width - 12, alignment: column.isTrailing ? .trailing : .leading)
                    .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, WindowLayout.inset)
        .frame(width: layout.detailWidth, height: WindowLayout.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(isSelected ? 1 : 0))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        }
    }

    private var secondary: Color { isSelected ? Color.white.opacity(0.85) : Color.secondary }

    @ViewBuilder
    private func cell(_ column: WindowLayout.Column) -> some View {
        switch column {
        case .size:
            Text(verbatim: copy.bytes(entry.size)).foregroundStyle(secondary)
        case .packed:
            Text(verbatim: copy.bytes(entry.packed)).foregroundStyle(secondary)
        case .saved:
            PromoBar(savings: entry.savings, label: copy.percent(entry.savings), isSelected: isSelected)
        case .modified:
            Text(verbatim: copy.date(entry.modified)).foregroundStyle(secondary)
        }
    }
}

/// `SavingsBar`, with the percentage in the video's language.
private struct PromoBar: View {
    let savings: Double
    let label: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(isSelected ? 0.3 : 0.12))
                Capsule().fill(fill).frame(width: max(3, 44 * savings))
            }
            .frame(width: 44, height: 5)
            Text(verbatim: label)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private var fill: Color {
        if isSelected { return .white }
        switch savings {
        case ..<0.1: return .gray
        case ..<0.4: return .teal
        default: return accent
        }
    }
}

/// `SavingsRing`, with the percentage in the video's language.
private struct PromoRing: View {
    let savings: Double
    let label: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, savings))
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct PromoJobCard: View {
    let job: PromoScript.Job
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.02, job.fraction))
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(verbatim: job.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .frame(width: isCompact ? 170 : 240, alignment: .leading)

            Text(verbatim: job.percent)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .chrome(Capsule(), fill: Color(white: 0.19))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}

private struct PromoNoticeCard: View {
    let notice: PromoScript.Notice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
            Text(verbatim: notice.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let button = notice.button {
                Text(verbatim: button)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accent))
            }
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .chrome(Capsule(), fill: Color(white: 0.19))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}
