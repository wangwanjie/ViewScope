import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum UpdateCheckStrategy: String, CaseIterable {
        case manual
        case daily
        case onLaunch

        var title: String {
            switch self {
            case .manual:
                return "Manual"
            case .daily:
                return "Daily"
            case .onLaunch:
                return "On Launch"
            }
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
    @Published var updateCheckStrategy: UpdateCheckStrategy {
        didSet { defaults.set(updateCheckStrategy.rawValue, forKey: Keys.updateCheckStrategy) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.autoRefreshEnabled = defaults.object(forKey: Keys.autoRefreshEnabled) as? Bool ?? false
        self.autoHighlightSelection = defaults.object(forKey: Keys.autoHighlightSelection) as? Bool ?? true
        self.showConnectedCountInStatusBar = defaults.object(forKey: Keys.showConnectedCountInStatusBar) as? Bool ?? true
        if let rawValue = defaults.string(forKey: Keys.updateCheckStrategy),
           let strategy = UpdateCheckStrategy(rawValue: rawValue) {
            self.updateCheckStrategy = strategy
        } else {
            self.updateCheckStrategy = .daily
        }
    }

    private enum Keys {
        static let autoRefreshEnabled = "ViewScope.autoRefreshEnabled"
        static let autoHighlightSelection = "ViewScope.autoHighlightSelection"
        static let showConnectedCountInStatusBar = "ViewScope.showConnectedCountInStatusBar"
        static let updateCheckStrategy = "ViewScope.updateCheckStrategy"
    }
}
