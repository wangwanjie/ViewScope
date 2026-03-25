import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var nativeDisplayName: String {
        switch self {
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        }
    }

    static func resolve(_ identifier: String?) -> AppLanguage? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            return nil
        }

        let normalized = identifier.lowercased()
        if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") {
            return .traditionalChinese
        }
        if normalized.hasPrefix("zh") {
            return .simplifiedChinese
        }
        if normalized.hasPrefix("en") {
            return .english
        }
        return nil
    }

    static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            if let language = resolve(identifier) {
                return language
            }
        }
        return .english
    }
}
