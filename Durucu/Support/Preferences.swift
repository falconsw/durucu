import Foundation

enum OpenBehavior: String, CaseIterable, Identifiable {
    case browse, extract
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browse: "İçeriğini göster"
        case .extract: "Hemen çıkart"
        }
    }
}

enum ExtractDestination: String, CaseIterable, Identifiable {
    case beside, ask, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: "Arşivle aynı klasöre"
        case .ask: "Her seferinde sor"
        case .custom: "Seçtiğim klasöre"
        }
    }
}

/// UserDefaults keys shared by `@AppStorage` views and non-view code.
enum Pref {
    static let openBehavior = "openBehavior"
    static let showMacMetadata = "showMacMetadata"
    static let autoPreview = "autoPreview"
    static let extractDestination = "extractDestination"
    static let customDestination = "customDestination"
    static let smartFolder = "smartFolder"
    static let revealAfterExtract = "revealAfterExtract"
    static let trashAfterQuickExtract = "trashAfterQuickExtract"
    static let defaultFormat = "defaultFormat"
    static let defaultLevel = "defaultLevel"
    static let excludeMacMetadata = "excludeMacMetadata"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openBehavior: OpenBehavior.browse.rawValue,
            showMacMetadata: false,
            autoPreview: true,
            extractDestination: ExtractDestination.beside.rawValue,
            customDestination: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path,
            smartFolder: true,
            revealAfterExtract: true,
            trashAfterQuickExtract: false,
            defaultFormat: OutputFormat.zip.rawValue,
            defaultLevel: CompressionLevel.balanced.rawValue,
            excludeMacMetadata: true,
        ])
    }

    private static var defaults: UserDefaults { .standard }

    static var openBehaviorValue: OpenBehavior {
        OpenBehavior(rawValue: defaults.string(forKey: openBehavior) ?? "") ?? .browse
    }

    static var extractDestinationValue: ExtractDestination {
        ExtractDestination(rawValue: defaults.string(forKey: extractDestination) ?? "") ?? .beside
    }

    static var customDestinationURL: URL {
        URL(fileURLWithPath: defaults.string(forKey: customDestination) ?? NSHomeDirectory(), isDirectory: true)
    }

    static var defaultFormatValue: OutputFormat {
        OutputFormat(rawValue: defaults.string(forKey: defaultFormat) ?? "") ?? .zip
    }

    static var defaultLevelValue: CompressionLevel {
        CompressionLevel(rawValue: defaults.string(forKey: defaultLevel) ?? "") ?? .balanced
    }

    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
}
