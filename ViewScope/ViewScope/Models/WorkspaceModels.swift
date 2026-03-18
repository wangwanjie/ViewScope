import CoreGraphics
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
            return L10n.waitingForDebugHost
        case .connecting(let name):
            return L10n.connecting(name)
        case .connected(let host):
            return L10n.connected(host.displayName)
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

enum WorkspacePreviewDisplayMode: String, CaseIterable {
    case flat
    case layered

    var symbolName: String {
        switch self {
        case .flat:
            return "square.on.square"
        case .layered:
            return "square.stack.3d.up"
        }
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

extension ViewScopeRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

extension ViewScopeSize {
    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}
