import Foundation

enum OpenBehavior: String, CaseIterable, Identifiable {
    case browse, extract
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browse: String(localized: "Show its contents")
        case .extract: String(localized: "Extract it right away")
        }
    }
}

enum ExtractDestination: String, CaseIterable, Identifiable {
    case beside, ask, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beside: String(localized: "Next to the archive")
        case .ask: String(localized: "Ask every time")
        case .custom: String(localized: "To a folder I choose")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Each language is named in itself, so it can be found whichever one is active.
    var title: String {
        switch self {
        case .english: "English"
        case .turkish: "Türkçe"
        }
    }

    static var preferred: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Pref.language) ?? "") ?? .english
    }

    /// The language this process is running in.
    static var active: AppLanguage {
        Bundle.main.preferredLocalizations.first == AppLanguage.turkish.rawValue ? .turkish : .english
    }

    /// macOS picks an app's language from `AppleLanguages` when it launches. Writing the
    /// preference there keeps English the default even on a Turkish system; a change
    /// takes effect on the next launch.
    static func apply() {
        UserDefaults.standard.set([preferred.rawValue], forKey: "AppleLanguages")
    }
}

/// UserDefaults keys shared by `@AppStorage` views and non-view code.
enum Pref {
    static let language = "appLanguage"
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
            language: AppLanguage.english.rawValue,
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
