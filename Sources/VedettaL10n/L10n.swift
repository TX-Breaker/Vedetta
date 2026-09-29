import Foundation

/// Localized text lookup. Keys are the English texts; translations live in
/// `Resources/Localization/<lang>.lproj/Localizable.strings` (generated from `Resources/Localization/strings.tsv`).
/// Arguments use `%@` placeholders (pass Strings) so every language can reorder them (`%1$@`, `%2$@`).
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, locale: AppLanguage.locale, arguments: args)
}

/// Language handling: follows macOS automatically, with an optional per-app override.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, italian = "it", english = "en", french = "fr"

    public var id: String { rawValue }

    /// Languages shipped with the app.
    public static let supported = ["en", "it", "fr"]

    /// Name shown in the language picker (each language in its own name).
    public var displayName: String {
        switch self {
        case .system: return L("Automatic (system language)")
        case .italian: return "Italiano"
        case .english: return "English"
        case .french: return "Français"
        }
    }

    /// Bundle holding the translations (the app bundle; falls back to main for command line tools).
    public static var bundle: Bundle { Bundle.main }

    /// The language actually used by the interface.
    public static var current: String {
        Bundle.main.preferredLocalizations.first.flatMap { supported.contains($0) ? $0 : nil }
            ?? Locale.preferredLanguages.first.map { String($0.prefix(2)) }.flatMap { supported.contains($0) ? $0 : nil }
            ?? "en"
    }

    /// Locale for dates and numbers: interface language + the user's region.
    public static var locale: Locale {
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { "\(current)_\($0)" } ?? current)
    }

    /// Current override stored in the app's defaults (nil = follow macOS).
    public static var override: AppLanguage {
        get {
            guard let list = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
                  UserDefaults.standard.object(forKey: "VedettaLanguageOverride") != nil,
                  let first = list.first, let lang = AppLanguage(rawValue: String(first.prefix(2))) else { return .system }
            return lang
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                UserDefaults.standard.removeObject(forKey: "VedettaLanguageOverride")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
                UserDefaults.standard.set(newValue.rawValue, forKey: "VedettaLanguageOverride")
            }
        }
    }
}
