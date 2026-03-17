import Foundation
import ViewScopeServer

struct CaptureHistoryInsight: Equatable {
    var totalCaptures: Int
    var averageDurationMilliseconds: Int
    var mostRecentDurationMilliseconds: Int

    static let empty = CaptureHistoryInsight(totalCaptures: 0, averageDurationMilliseconds: 0, mostRecentDurationMilliseconds: 0)
}

enum WorkspaceConnectionState: Equatable {
    case idle
    case connecting(String)
    case connected(ViewScopeHostAnnouncement)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Waiting for a debug host"
        case .connecting(let name):
            return "Connecting to \(name)..."
        case .connected(let host):
            return "Connected to \(host.displayName)"
        case .failed(let message):
            return message
        }
    }

    var activeHost: ViewScopeHostAnnouncement? {
        if case .connected(let host) = self {
            return host
        }
        return nil
    }
}

struct HostListItem: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var detail: String
    var isRecent: Bool
    var announcement: ViewScopeHostAnnouncement?
    var recentRecord: RecentHostRecord?
}
