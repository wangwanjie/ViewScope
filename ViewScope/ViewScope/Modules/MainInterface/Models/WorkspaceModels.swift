import CoreGraphics
import Foundation
import ViewScopeServer

nonisolated struct CaptureHistoryInsight: Equatable, Sendable {
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
    /// 已连接的宿主意外断开：保留最后一次抓取供只读查看，等待宿主重新出现后自动重连。
    case lost(ViewScopeHostAnnouncement)

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
        case .lost:
            return L10n.connectedHostDisappeared
        }
    }

    /// 意外断开的宿主（只读模式）。
    var lostHost: ViewScopeHostAnnouncement? {
        if case .lost(let host) = self {
            return host
        }
        return nil
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
    /// 导出预览文件时顺带保存的“当前预览状态”。
    ///
    /// 这部分并不是抓取数据本身，而是为了让导入后仍能恢复当时的预览上下文：
    /// 选中了谁、focus 在哪、当前是 2D 还是 3D、缩放多少、展开了哪些节点。
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

/// 预览归档编解码器。
/// 外层用 `NSKeyedArchiver` 打包文档对象，内层 payload 仍然是 plist，方便未来演进版本。
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
        let document: WorkspaceArchiveDocument?
        do {
            document = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: WorkspaceArchiveDocument.self,
                from: data
            )
        } catch {
            throw WorkspaceArchiveError.unsupportedFile
        }
        guard let document else {
            throw WorkspaceArchiveError.unsupportedFile
        }
        // 新版本客户端写出的归档可能含有当前版本无法理解的结构，直接拒绝而不是解出半截数据
        guard document.archiveVersion <= supportedArchiveVersion else {
            throw WorkspaceArchiveError.unsupportedVersion
        }

        let decoder = PropertyListDecoder()
        let export: WorkspaceRawPreviewExport
        do {
            export = try decoder.decode(WorkspaceRawPreviewExport.self, from: document.payloadData)
        } catch {
            throw WorkspaceArchiveError.corruptedPayload(underlyingError: error)
        }
        guard export.formatVersion <= supportedFormatVersion else {
            throw WorkspaceArchiveError.unsupportedVersion
        }
        return export
    }

    /// 当前客户端能读取的最高归档版本。
    static let supportedArchiveVersion = 1
    /// 当前客户端能读取的最高 payload 格式版本。
    static let supportedFormatVersion = 1
}

enum WorkspaceArchiveError: LocalizedError {
    case unsupportedFile
    case unsupportedVersion
    case corruptedPayload(underlyingError: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return AppLocalization.backgroundString("archive.error.unsupported_file")
        case .unsupportedVersion:
            return AppLocalization.backgroundString("app.archive.error.unsupported_version")
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
