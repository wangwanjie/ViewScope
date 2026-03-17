import Combine
import Foundation
import ViewScopeServer

@MainActor
final class DiscoveryCenter: NSObject {
    @Published private(set) var announcements: [ViewScopeHostAnnouncement] = []

    private var announcementsByIdentifier: [String: ViewScopeHostAnnouncement] = [:]
    private var announcementObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pruneTimer: Timer?

    func start() {
        guard announcementObserver == nil else { return }

        announcementObserver = DistributedNotificationCenter.default().addObserver(
            forName: viewScopeDiscoveryAnnouncementNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let payload = notification.userInfo?["payload"] as? String
            MainActor.assumeIsolated {
                self?.handleAnnouncementPayload(payload)
            }
        }

        terminationObserver = DistributedNotificationCenter.default().addObserver(
            forName: viewScopeDiscoveryTerminationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let identifier = notification.userInfo?["identifier"] as? String
            MainActor.assumeIsolated {
                self?.handleTermination(identifier: identifier)
            }
        }

        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneStaleAnnouncements()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer

        DistributedNotificationCenter.default().postNotificationName(
            viewScopeDiscoveryRequestNotification,
            object: nil,
            userInfo: nil,
            options: [.deliverImmediately]
        )
    }

    func stop() {
        if let announcementObserver {
            DistributedNotificationCenter.default().removeObserver(announcementObserver)
        }
        if let terminationObserver {
            DistributedNotificationCenter.default().removeObserver(terminationObserver)
        }
        announcementObserver = nil
        terminationObserver = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func handleAnnouncementPayload(_ payload: String?) {
        guard let payload,
              let data = payload.data(using: .utf8),
              let announcement = try? JSONDecoder.viewScope.decode(ViewScopeHostAnnouncement.self, from: data) else {
            return
        }
        announcementsByIdentifier[announcement.identifier] = announcement
        publishAnnouncements()
    }

    private func handleTermination(identifier: String?) {
        guard let identifier else { return }
        announcementsByIdentifier.removeValue(forKey: identifier)
        publishAnnouncements()
    }

    private func pruneStaleAnnouncements() {
        let expirationInterval: TimeInterval = 6
        let now = Date()
        announcementsByIdentifier = announcementsByIdentifier.filter { _, announcement in
            now.timeIntervalSince(announcement.updatedAt) < expirationInterval
        }
        publishAnnouncements()
    }

    private func publishAnnouncements() {
        announcements = announcementsByIdentifier.values.sorted { left, right in
            if left.displayName == right.displayName {
                return left.processIdentifier < right.processIdentifier
            }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }
}

private extension JSONDecoder {
    static var viewScope: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
