import AppKit
import Combine
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

struct ReleaseVersion: Comparable {
    let rawValue: String
    private let components: [Int]

    init(_ rawValue: String) {
        self.rawValue = rawValue
        self.components = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive], range: nil)
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return false
            }
        }
        return true
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
    }
}

@MainActor
/// Checks for new ViewScope releases through Sparkle when available, with a GitHub fallback.
final class UpdateManager: NSObject {
    private let lastUpdateCheckKey = "ViewScope.lastUpdateCheck"
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    #if canImport(Sparkle)
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    #endif

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
    }

    func configure() {
        guard !updatesDisabledForEnvironment else { return }
        bindSettingsIfNeeded()
        #if canImport(Sparkle)
        guard sparkleUpdaterController == nil, isSparkleConfigured else { return }
        sparkleUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        applySparkleSettings()
        #endif
    }

    func scheduleBackgroundUpdateCheck() {
        guard !updatesDisabledForEnvironment else { return }
        switch settings.updateCheckStrategy {
        case .manual:
            return
        case .daily:
            if let lastCheckDate = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date,
               Date().timeIntervalSince(lastCheckDate) < 24 * 60 * 60 {
                return
            }
        case .onLaunch:
            break
        }

        #if canImport(Sparkle)
        if let sparkleUpdaterController {
            sparkleUpdaterController.updater.checkForUpdatesInBackground()
            return
        }
        #endif

        Task { await checkLatestGitHubRelease(interactive: false) }
    }

    func checkForUpdates() {
        guard !updatesDisabledForEnvironment else { return }
        #if canImport(Sparkle)
        if let sparkleUpdaterController {
            sparkleUpdaterController.checkForUpdates(nil)
            return
        }
        #endif

        Task { await checkLatestGitHubRelease(interactive: true) }
    }

    var supportsAutomaticUpdateDownloads: Bool {
        #if canImport(Sparkle)
        sparkleUpdaterController?.updater.allowsAutomaticUpdates ?? false
        #else
        false
        #endif
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            #if canImport(Sparkle)
            sparkleUpdaterController?.updater.automaticallyDownloadsUpdates ?? false
            #else
            false
            #endif
        }
        set {
            #if canImport(Sparkle)
            sparkleUpdaterController?.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }

    func openGitHubHomepage() {
        guard let url = repositoryURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var repositoryURL: URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "ViewScopeGitHubURL") as? String else { return nil }
        return URL(string: rawValue)
    }

    private var latestReleaseAPIURL: URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "ViewScopeGitHubLatestReleaseAPIURL") as? String else { return nil }
        return URL(string: rawValue)
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var updatesDisabledForEnvironment: Bool {
        settings.environment["VIEWSCOPE_DISABLE_UPDATES"] == "1"
    }

    #if canImport(Sparkle)
    private var isSparkleConfigured: Bool {
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !feedURL.isEmpty && !publicKey.isEmpty
    }

    private func applySparkleSettings() {
        guard let updater = sparkleUpdaterController?.updater else { return }
        switch settings.updateCheckStrategy {
        case .manual:
            updater.automaticallyChecksForUpdates = false
        case .daily:
            updater.updateCheckInterval = 24 * 60 * 60
            updater.automaticallyChecksForUpdates = true
        case .onLaunch:
            updater.automaticallyChecksForUpdates = false
        }
    }
    #endif

    private func bindSettingsIfNeeded() {
        guard cancellables.isEmpty else { return }
        settings.$updateCheckStrategy
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                #if canImport(Sparkle)
                self?.applySparkleSettings()
                #endif
            }
            .store(in: &cancellables)
    }

    private func checkLatestGitHubRelease(interactive: Bool) async {
        guard let latestReleaseAPIURL else { return }

        do {
            var request = URLRequest(url: latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ViewScope", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            UserDefaults.standard.set(Date(), forKey: lastUpdateCheckKey)
            presentReleaseResult(release, interactive: interactive)
        } catch {
            if interactive {
                presentFailureAlert(message: error.localizedDescription)
            }
        }
    }

    private func presentReleaseResult(_ release: GitHubRelease, interactive: Bool) {
        let current = ReleaseVersion(currentVersion)
        let latest = ReleaseVersion(release.tagName)

        guard latest > current else {
            if interactive {
                let alert = NSAlert()
                alert.messageText = L10n.updateUpToDateTitle
                alert.informativeText = L10n.updateUpToDateBody(current: currentVersion, latest: release.tagName)
                alert.runModal()
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.updateAvailableTitle(release.tagName)
        alert.informativeText = release.body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? L10n.updateAvailableFallback
        alert.addButton(withTitle: L10n.updateButtonOpenGitHub)
        alert.addButton(withTitle: L10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func presentFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.updateFailureTitle
        alert.informativeText = message
        alert.runModal()
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
