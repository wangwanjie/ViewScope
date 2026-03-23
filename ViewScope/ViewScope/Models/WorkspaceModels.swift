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
    case imported(String)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return L10n.waitingForDebugHost
        case .connecting(let name):
            return L10n.connecting(name)
        case .connected(let host):
            return L10n.connected(host.displayName)
        case .imported(let name):
            return L10n.loadedCaptureFile(name)
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

    var importedCaptureName: String? {
        if case .imported(let name) = self {
            return name
        }
        return nil
    }

    var supportsConsole: Bool {
        activeHost != nil
    }
}

enum WorkspacePreviewDisplayMode: String, CaseIterable, Codable {
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

struct WorkspaceRawPreviewExport: Codable, Equatable {
    struct PreviewContext: Codable, Equatable {
        var selectedNodeID: String?
        var focusedNodeID: String?
        var previewRootNodeID: String?
        var geometryMode: String
        var previewScale: Double
        var previewDisplayMode: WorkspacePreviewDisplayMode
        var previewLayerSpacing: Double
        var previewShowsLayerBorders: Bool
        var expandedNodeIDs: [String]
    }

    var formatVersion: Int
    var exportedAt: Date
    var capture: ViewScopeCapturePayload
    var selectedNodeDetail: ViewScopeNodeDetailPayload?
    var previewBitmap: ViewScopePreviewBitmap?
    var previewContext: PreviewContext
}

enum WorkspaceArchiveCodec {
    static let typeIdentifier = "cn.vanjay.viewscope.capture"
    static let fileExtension = "viewscope"

    static func encode(_ export: WorkspaceRawPreviewExport) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadData = try encoder.encode(export)
        let document = WorkspaceArchiveDocument(payloadData: payloadData)
        return try NSKeyedArchiver.archivedData(withRootObject: document, requiringSecureCoding: true)
    }

    static func decode(_ data: Data) throws -> WorkspaceRawPreviewExport {
        guard let document = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: WorkspaceArchiveDocument.self,
            from: data
        ) else {
            throw WorkspaceArchiveError.unsupportedFile
        }

        let decoder = PropertyListDecoder()
        do {
            return try decoder.decode(WorkspaceRawPreviewExport.self, from: document.payloadData)
        } catch {
            throw WorkspaceArchiveError.corruptedPayload(underlyingError: error)
        }
    }
}

enum WorkspaceArchiveError: LocalizedError {
    case unsupportedFile
    case corruptedPayload(underlyingError: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return AppLocalization.backgroundString("archive.error.unsupported_file")
        case .corruptedPayload:
            return AppLocalization.backgroundString("archive.error.corrupted_file")
        }
    }
}

@objc(WorkspaceArchiveDocument)
final class WorkspaceArchiveDocument: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    private enum Keys {
        static let archiveVersion = "archiveVersion"
        static let payloadData = "payloadData"
    }

    let archiveVersion: Int
    let payloadData: Data

    init(archiveVersion: Int = 1, payloadData: Data) {
        self.archiveVersion = archiveVersion
        self.payloadData = payloadData
        super.init()
    }

    required init?(coder: NSCoder) {
        let archiveVersion = coder.decodeInteger(forKey: Keys.archiveVersion)
        guard let payloadData = coder.decodeObject(of: NSData.self, forKey: Keys.payloadData) as Data? else {
            return nil
        }

        self.archiveVersion = archiveVersion
        self.payloadData = payloadData
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(archiveVersion, forKey: Keys.archiveVersion)
        coder.encode(payloadData as NSData, forKey: Keys.payloadData)
    }
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
