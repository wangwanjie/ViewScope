import Combine
import Foundation

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()

    @Published private(set) var language: AppLanguage = .english

    var locale: Locale {
        language.locale
    }

    func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
    }

    func string(_ key: String, _ arguments: CVarArg..., table: String = "Localizable") -> String {
        string(key, arguments: arguments, table: table)
    }

    func string(_ key: String, arguments: [CVarArg], table: String = "Localizable") -> String {
        let format = localizedBundle.localizedString(forKey: key, value: nil, table: table)
        guard arguments.isEmpty == false else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    nonisolated static func backgroundString(_ key: String, _ arguments: CVarArg..., table: String = "Localizable") -> String {
        backgroundString(key, arguments: arguments, table: table)
    }

    nonisolated static func backgroundString(_ key: String, arguments: [CVarArg], table: String = "Localizable") -> String {
        let rawLanguage = UserDefaults.standard.string(forKey: "ViewScope.appLanguage")
        let resolvedLanguage: String = {
            let preferred = rawLanguage ?? Locale.preferredLanguages.first ?? "en"
            let normalized = preferred.lowercased()
            if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if normalized.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        }()
        let bundle: Bundle
        if let path = Bundle.main.path(forResource: resolvedLanguage, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            bundle = localizedBundle
        } else {
            bundle = .main
        }

        let format = bundle.localizedString(forKey: key, value: nil, table: table)
        guard arguments.isEmpty == false else { return format }
        return String(format: format, locale: Locale(identifier: resolvedLanguage), arguments: arguments)
    }
}
