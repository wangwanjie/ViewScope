import Combine
import Foundation

@MainActor
/// Persists user-configurable ViewScope preferences and keeps localization in sync.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum UpdateCheckStrategy: String, CaseIterable {
        case manual
        case daily
        case onLaunch

        var title: String {
            switch self {
            case .manual:
                return L10n.updateStrategyManual
            case .daily:
                return L10n.updateStrategyDaily
            case .onLaunch:
                return L10n.updateStrategyOnLaunch
            }
        }
    }

    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            AppLocalization.shared.setLanguage(appLanguage)
        }
    }

    @Published var autoRefreshEnabled: Bool {
        didSet { defaults.set(autoRefreshEnabled, forKey: Keys.autoRefreshEnabled) }
    }
    @Published var autoHighlightSelection: Bool {
        didSet { defaults.set(autoHighlightSelection, forKey: Keys.autoHighlightSelection) }
    }
    @Published var showConnectedCountInStatusBar: Bool {
        didSet { defaults.set(showConnectedCountInStatusBar, forKey: Keys.showConnectedCountInStatusBar) }
    }
    @Published var showsSessionSidebar: Bool {
        didSet { defaults.set(showsSessionSidebar, forKey: Keys.showsSessionSidebar) }
    }
    @Published var showsInspector: Bool {
        didSet { defaults.set(showsInspector, forKey: Keys.showsInspector) }
    }
    @Published var updateCheckStrategy: UpdateCheckStrategy {
        didSet { defaults.set(updateCheckStrategy.rawValue, forKey: Keys.updateCheckStrategy) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.appLanguage = Self.resolveLanguage(defaults: defaults, environment: environment)
        self.autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? false
        self.autoHighlightSelection = defaults.object(forKey: Keys.autoHighlightSelection) as? Bool ?? false
        self.showConnectedCountInStatusBar = defaults.object(forKey: Keys.showConnectedCountInStatusBar) as? Bool ?? true
        self.showsSessionSidebar = defaults.object(forKey: Keys.showsSessionSidebar) as? Bool ?? true
        self.showsInspector = defaults.object(forKey: Keys.showsInspector) as? Bool ?? true
        if let rawValue = defaults.string(forKey: Keys.updateCheckStrategy),
           let strategy = UpdateCheckStrategy(rawValue: rawValue) {
            self.updateCheckStrategy = strategy
        } else {
            self.updateCheckStrategy = .daily
        }
        AppLocalization.shared.setLanguage(appLanguage)
    }

    private enum Keys {
        static let appLanguage = "ViewScope.appLanguage"
        static let autoRefreshEnabled = "ViewScope.autoRefreshEnabled"
        static let autoHighlightSelection = "ViewScope.autoHighlightSelection"
        static let showConnectedCountInStatusBar = "ViewScope.showConnectedCountInStatusBar"
        static let showsSessionSidebar = "ViewScope.showsSessionSidebar"
        static let showsInspector = "ViewScope.showsInspector"
        static let updateCheckStrategy = "ViewScope.updateCheckStrategy"
    }

    private static func resolveLanguage(defaults: UserDefaults, environment: [String: String]) -> AppLanguage {
        if let language = AppLanguage.resolve(environment["VIEWSCOPE_LANGUAGE"]) {
            return language
        }
        if let language = AppLanguage.resolve(defaults.string(forKey: Keys.appLanguage)) {
            return language
        }
        return AppLanguage.preferred(from: Locale.preferredLanguages)
    }
}
