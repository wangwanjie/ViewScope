import Foundation

public let viewScopeDiscoveryAnnouncementNotification = Notification.Name("cn.vanjay.ViewScopeServer.announcement")
public let viewScopeDiscoveryTerminationNotification = Notification.Name("cn.vanjay.ViewScopeServer.termination")
public let viewScopeDiscoveryRequestNotification = Notification.Name("cn.vanjay.ViewScopeServer.discovery-request")
/// 当前协议版本。v3 新增：端口扫描发现、iOS 宿主信息、节点 traits、可枚举编辑项、console 补全与 ping。
public let viewScopeCurrentProtocolVersion = 3
/// 服务端仍可接受的最低客户端协议版本，客户端连接旧宿主时也按此降级。
public let viewScopeMinimumSupportedProtocolVersion = 2
public let viewScopeServerRuntimeVersion = "1.3.0"
/// 宿主监听端口段。
///
/// - iOS 模拟器与 Mac 共享 loopback，客户端直接扫描 `127.0.0.1` 上的这些端口；
/// - iOS 真机通过 usbmuxd 把同一段端口转发到设备的 loopback；
/// - macOS 宿主也优先占用这段端口，使开启 App Sandbox（带 network.server 权限）的宿主也能被扫描发现。
public let viewScopeHostPortRange: ClosedRange<UInt16> = 47300...47339

/// 宿主运行平台。
public enum ViewScopePlatform: String, Codable, Sendable, Hashable {
    case macOS
    case iOS
    case iPadOS
    case macCatalyst
    case tvOS
    case visionOS
}

/// 客户端如何到达宿主。由客户端在发现阶段填写，服务端不需要关心。
public struct ViewScopeHostTransport: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// 直接连接 `127.0.0.1:port`（macOS 宿主、iOS 模拟器）。
        case loopback
        /// 通过 usbmuxd 隧道连接真机上的 `port`。
        case usbmux
    }

    public var kind: Kind
    /// usbmuxd 分配的 DeviceID，仅 `.usbmux` 使用。
    public var deviceID: Int?
    /// 设备 UDID / SerialNumber，仅 `.usbmux` 使用。
    public var deviceSerial: String?
    /// usbmuxd 报告的连接类型（USB / Network）。
    public var connectionType: String?

    public init(kind: Kind, deviceID: Int? = nil, deviceSerial: String? = nil, connectionType: String? = nil) {
        self.kind = kind
        self.deviceID = deviceID
        self.deviceSerial = deviceSerial
        self.connectionType = connectionType
    }

    public static let loopback = ViewScopeHostTransport(kind: .loopback)
}

/// Advertises a locally running debug host that can be inspected by the ViewScope app.
public struct ViewScopeHostAnnouncement: Codable, Sendable, Hashable {
    public var identifier: String
    public var authToken: String
    public var displayName: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var processIdentifier: Int32
    public var port: UInt16
    public var updatedAt: Date
    public var supportsHighlighting: Bool
    public var protocolVersion: Int
    public var runtimeVersion: String
    /// v3：宿主平台；旧宿主为 nil，按 macOS 处理。
    public var platform: ViewScopePlatform?
    /// v3：系统版本，例如 "17.5"。
    public var osVersion: String?
    /// v3：设备名（iOS 为 UIDevice.name，macOS 为主机名）。
    public var deviceName: String?
    /// v3：设备型号标识，例如 "iPhone15,2"、"MacBookPro18,3"。
    public var deviceModel: String?
    /// v3：是否运行在 iOS 模拟器。
    public var isSimulator: Bool?
    /// v3：主屏幕缩放比例。
    public var screenScale: Double?
    /// 客户端填写：到达该宿主的方式。nil 视为 `.loopback`。
    public var transport: ViewScopeHostTransport?

    public init(
        identifier: String,
        authToken: String,
        displayName: String,
        bundleIdentifier: String,
        version: String,
        build: String,
        processIdentifier: Int32,
        port: UInt16,
        updatedAt: Date,
        supportsHighlighting: Bool,
        protocolVersion: Int,
        runtimeVersion: String,
        platform: ViewScopePlatform? = nil,
        osVersion: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        isSimulator: Bool? = nil,
        screenScale: Double? = nil,
        transport: ViewScopeHostTransport? = nil
    ) {
        self.identifier = identifier
        self.authToken = authToken
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.processIdentifier = processIdentifier
        self.port = port
        self.updatedAt = updatedAt
        self.supportsHighlighting = supportsHighlighting
        self.protocolVersion = protocolVersion
        self.runtimeVersion = runtimeVersion
        self.platform = platform
        self.osVersion = osVersion
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.isSimulator = isSimulator
        self.screenScale = screenScale
        self.transport = transport
    }

    /// 旧宿主没有 platform 字段，统一按 macOS 处理。
    public var resolvedPlatform: ViewScopePlatform {
        platform ?? .macOS
    }

    /// 实际到达方式，旧数据视为 loopback。
    public var resolvedTransport: ViewScopeHostTransport {
        transport ?? .loopback
    }
}

public struct ViewScopeHostInfo: Codable, Sendable, Hashable {
    public var displayName: String
    public var bundleIdentifier: String
    public var version: String
    public var build: String
    public var processIdentifier: Int32
    public var runtimeVersion: String
    public var supportsHighlighting: Bool
    /// v3：宿主平台；旧宿主为 nil，按 macOS 处理。
    public var platform: ViewScopePlatform?
    public var osVersion: String?
    public var deviceName: String?
    public var deviceModel: String?
    public var isSimulator: Bool?
    public var screenScale: Double?
    /// v3：服务端实际使用的协议版本。
    public var protocolVersion: Int?

    public init(
        displayName: String,
        bundleIdentifier: String,
        version: String,
        build: String,
        processIdentifier: Int32,
        runtimeVersion: String,
        supportsHighlighting: Bool,
        platform: ViewScopePlatform? = nil,
        osVersion: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        isSimulator: Bool? = nil,
        screenScale: Double? = nil,
        protocolVersion: Int? = nil
    ) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.processIdentifier = processIdentifier
        self.runtimeVersion = runtimeVersion
        self.supportsHighlighting = supportsHighlighting
        self.platform = platform
        self.osVersion = osVersion
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.isSimulator = isSimulator
        self.screenScale = screenScale
        self.protocolVersion = protocolVersion
    }

    public var resolvedPlatform: ViewScopePlatform {
        platform ?? .macOS
    }
}

public struct ViewScopeRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = ViewScopeRect(x: 0, y: 0, width: 0, height: 0)
}

public struct ViewScopeSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = ViewScopeSize(width: 0, height: 0)
}

public struct ViewScopeIvarTrace: Codable, Sendable, Hashable {
    public var relation: String?
    public var hostClassName: String
    public var ivarName: String

    public init(relation: String? = nil, hostClassName: String, ivarName: String) {
        self.relation = relation
        self.hostClassName = hostClassName
        self.ivarName = ivarName
    }
}

public struct ViewScopeEventTargetAction: Codable, Sendable, Hashable {
    public var targetClassName: String?
    public var actionName: String?

    public init(targetClassName: String?, actionName: String?) {
        self.targetClassName = targetClassName
        self.actionName = actionName
    }
}

public struct ViewScopeEventHandler: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case controlAction
        case gesture
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var targetActions: [ViewScopeEventTargetAction]
    public var isEnabled: Bool?
    public var delegateClassName: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        title: String,
        subtitle: String? = nil,
        targetActions: [ViewScopeEventTargetAction] = [],
        isEnabled: Bool? = nil,
        delegateClassName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.targetActions = targetActions
        self.isEnabled = isEnabled
        self.delegateClassName = delegateClassName
    }
}

/// v3：供客户端做布局诊断、可访问性检查的附加信息。所有字段都可缺省。
public struct ViewScopeNodeTraits: Codable, Sendable, Hashable {
    /// UIView.isUserInteractionEnabled；AppKit 下对应“会参与 hitTest”（未隐藏且非 ignoresMouseEvents 语义），无法判断时为 nil。
    public var isUserInteractionEnabled: Bool?
    /// Auto Layout 是否存在歧义（`hasAmbiguousLayout`）。
    public var hasAmbiguousLayout: Bool?
    public var translatesAutoresizingMaskIntoConstraints: Bool?
    /// 视图/图层是否声明为不透明。
    public var isOpaque: Bool?
    /// 背景色的 alpha；没有背景色时为 nil。
    public var backgroundAlpha: Double?
    /// 节点在父视图坐标系中的原始 frame（未做画布归一化），单位 point。
    public var frameInSuperview: ViewScopeRect?
    /// 渲染缩放比例（backingScaleFactor / contentScaleFactor），用于检查像素对齐。
    public var displayScale: Double?
    /// 固有尺寸；没有固有尺寸时为 nil。
    public var intrinsicContentSize: ViewScopeSize?
    /// 与该节点相关的约束数量（自身 + 父视图中引用它的约束）。
    public var constraintCount: Int?
    public var accessibilityIdentifier: String?
    public var accessibilityLabel: String?
    public var isAccessibilityElement: Bool?
    /// 是否为可交互控件（UIControl / NSControl / 带手势），用于点击区域检查。
    public var isInteractiveControl: Bool?
    /// 文本类控件的文本是否被截断（UILabel / NSTextField 等），无法判断时为 nil。
    public var isTextTruncated: Bool?
    /// 图片视图所显示图片的尺寸（point），用于放大模糊检查。
    public var imageSize: ViewScopeSize?
    /// 图片本身的 scale。
    public var imageScale: Double?

    public init(
        isUserInteractionEnabled: Bool? = nil,
        hasAmbiguousLayout: Bool? = nil,
        translatesAutoresizingMaskIntoConstraints: Bool? = nil,
        isOpaque: Bool? = nil,
        backgroundAlpha: Double? = nil,
        frameInSuperview: ViewScopeRect? = nil,
        displayScale: Double? = nil,
        intrinsicContentSize: ViewScopeSize? = nil,
        constraintCount: Int? = nil,
        accessibilityIdentifier: String? = nil,
        accessibilityLabel: String? = nil,
        isAccessibilityElement: Bool? = nil,
        isInteractiveControl: Bool? = nil,
        isTextTruncated: Bool? = nil,
        imageSize: ViewScopeSize? = nil,
        imageScale: Double? = nil
    ) {
        self.isUserInteractionEnabled = isUserInteractionEnabled
        self.hasAmbiguousLayout = hasAmbiguousLayout
        self.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
        self.isOpaque = isOpaque
        self.backgroundAlpha = backgroundAlpha
        self.frameInSuperview = frameInSuperview
        self.displayScale = displayScale
        self.intrinsicContentSize = intrinsicContentSize
        self.constraintCount = constraintCount
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessibilityLabel = accessibilityLabel
        self.isAccessibilityElement = isAccessibilityElement
        self.isInteractiveControl = isInteractiveControl
        self.isTextTruncated = isTextTruncated
        self.imageSize = imageSize
        self.imageScale = imageScale
    }
}

public struct ViewScopeHierarchyNode: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case window
        case view
        case layer
    }

    public var id: String
    public var parentID: String?
    public var kind: Kind
    public var className: String
    public var hostViewClassName: String?
    public var title: String
    public var subtitle: String?
    public var ivarName: String?
    public var ivarTraces: [ViewScopeIvarTrace]
    public var rootViewControllerClassName: String?
    public var controlTargetClassName: String?
    public var controlActionName: String?
    public var eventHandlers: [ViewScopeEventHandler]?
    public var identifier: String?
    public var address: String?
    public var frame: ViewScopeRect
    public var bounds: ViewScopeRect
    public var childIDs: [String]
    public var isHidden: Bool
    public var alphaValue: Double
    public var wantsLayer: Bool
    public var isFlipped: Bool
    public var clippingEnabled: Bool
    public var depth: Int
    /// v3：诊断用附加信息。
    public var traits: ViewScopeNodeTraits?

    public init(
        id: String,
        parentID: String?,
        kind: Kind,
        className: String,
        hostViewClassName: String? = nil,
        title: String,
        subtitle: String?,
        identifier: String? = nil,
        address: String? = nil,
        frame: ViewScopeRect,
        bounds: ViewScopeRect,
        childIDs: [String],
        isHidden: Bool,
        alphaValue: Double,
        wantsLayer: Bool,
        isFlipped: Bool,
        clippingEnabled: Bool,
        depth: Int,
        ivarName: String? = nil,
        ivarTraces: [ViewScopeIvarTrace] = [],
        rootViewControllerClassName: String? = nil,
        controlTargetClassName: String? = nil,
        controlActionName: String? = nil,
        eventHandlers: [ViewScopeEventHandler]? = nil,
        traits: ViewScopeNodeTraits? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.className = className
        self.hostViewClassName = hostViewClassName
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.address = address
        self.frame = frame
        self.bounds = bounds
        self.childIDs = childIDs
        self.isHidden = isHidden
        self.alphaValue = alphaValue
        self.wantsLayer = wantsLayer
        self.isFlipped = isFlipped
        self.clippingEnabled = clippingEnabled
        self.depth = depth
        self.ivarName = ivarName
        self.ivarTraces = ivarTraces
        self.rootViewControllerClassName = rootViewControllerClassName
        self.controlTargetClassName = controlTargetClassName
        self.controlActionName = controlActionName
        self.eventHandlers = eventHandlers
        self.traits = traits
    }
}

public struct ViewScopeCaptureSummary: Codable, Sendable, Hashable {
    public var nodeCount: Int
    public var windowCount: Int
    public var visibleWindowCount: Int
    public var captureDurationMilliseconds: Int

    public init(nodeCount: Int, windowCount: Int, visibleWindowCount: Int, captureDurationMilliseconds: Int) {
        self.nodeCount = nodeCount
        self.windowCount = windowCount
        self.visibleWindowCount = visibleWindowCount
        self.captureDurationMilliseconds = captureDurationMilliseconds
    }
}

public struct ViewScopePreviewBitmap: Codable, Sendable, Hashable {
    public var rootNodeID: String
    public var pngBase64: String
    public var size: ViewScopeSize
    public var capturedAt: Date
    public var scale: Double?

    public init(
        rootNodeID: String,
        pngBase64: String,
        size: ViewScopeSize,
        capturedAt: Date,
        scale: Double? = nil
    ) {
        self.rootNodeID = rootNodeID
        self.pngBase64 = pngBase64
        self.size = size
        self.capturedAt = capturedAt
        self.scale = scale
    }
}

public struct ViewScopeNodePreviewScreenshotSet: Codable, Sendable, Hashable {
    public var nodeID: String
    public var groupPNGBase64: String?
    public var soloPNGBase64: String?
    public var size: ViewScopeSize
    public var capturedAt: Date
    public var scale: Double?

    public init(
        nodeID: String,
        groupPNGBase64: String? = nil,
        soloPNGBase64: String? = nil,
        size: ViewScopeSize,
        capturedAt: Date,
        scale: Double? = nil
    ) {
        self.nodeID = nodeID
        self.groupPNGBase64 = groupPNGBase64
        self.soloPNGBase64 = soloPNGBase64
        self.size = size
        self.capturedAt = capturedAt
        self.scale = scale
    }
}

/// Contains a full hierarchy snapshot for the current host capture.
public struct ViewScopeCapturePayload: Codable, Sendable, Hashable {
    public var host: ViewScopeHostInfo
    public var capturedAt: Date
    public var summary: ViewScopeCaptureSummary
    public var rootNodeIDs: [String]
    public var nodes: [String: ViewScopeHierarchyNode]
    public var captureID: String
    public var previewBitmaps: [ViewScopePreviewBitmap]
    public var nodePreviewScreenshots: [ViewScopeNodePreviewScreenshotSet]

    public init(
        host: ViewScopeHostInfo,
        capturedAt: Date,
        summary: ViewScopeCaptureSummary,
        rootNodeIDs: [String],
        nodes: [String: ViewScopeHierarchyNode],
        captureID: String = UUID().uuidString,
        previewBitmaps: [ViewScopePreviewBitmap] = [],
        nodePreviewScreenshots: [ViewScopeNodePreviewScreenshotSet] = []
    ) {
        self.host = host
        self.capturedAt = capturedAt
        self.summary = summary
        self.rootNodeIDs = rootNodeIDs
        self.nodes = nodes
        self.captureID = captureID
        self.previewBitmaps = previewBitmaps
        self.nodePreviewScreenshots = nodePreviewScreenshots
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case capturedAt
        case summary
        case rootNodeIDs
        case nodes
        case captureID
        case previewBitmaps
        case nodePreviewScreenshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(ViewScopeHostInfo.self, forKey: .host)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        summary = try container.decode(ViewScopeCaptureSummary.self, forKey: .summary)
        rootNodeIDs = try container.decode([String].self, forKey: .rootNodeIDs)
        nodes = try container.decode([String: ViewScopeHierarchyNode].self, forKey: .nodes)
        captureID = try container.decodeIfPresent(String.self, forKey: .captureID) ?? UUID().uuidString
        previewBitmaps = try container.decodeIfPresent([ViewScopePreviewBitmap].self, forKey: .previewBitmaps) ?? []
        nodePreviewScreenshots = try container.decodeIfPresent([ViewScopeNodePreviewScreenshotSet].self, forKey: .nodePreviewScreenshots) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(summary, forKey: .summary)
        try container.encode(rootNodeIDs, forKey: .rootNodeIDs)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(captureID, forKey: .captureID)
        try container.encode(previewBitmaps, forKey: .previewBitmaps)
        try container.encode(nodePreviewScreenshots, forKey: .nodePreviewScreenshots)
    }
}

public struct ViewScopeRemoteObjectReference: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case window
        case view
        case layer
        case viewController
        case returnedObject
    }

    public var captureID: String
    public var objectID: String
    public var kind: Kind
    public var className: String
    public var address: String?
    public var sourceNodeID: String?

    public init(
        captureID: String,
        objectID: String,
        kind: Kind,
        className: String,
        address: String? = nil,
        sourceNodeID: String? = nil
    ) {
        self.captureID = captureID
        self.objectID = objectID
        self.kind = kind
        self.className = className
        self.address = address
        self.sourceNodeID = sourceNodeID
    }
}

public struct ViewScopeConsoleTargetDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { reference.objectID }
    public var reference: ViewScopeRemoteObjectReference
    public var title: String
    public var subtitle: String?

    public init(reference: ViewScopeRemoteObjectReference, title: String, subtitle: String? = nil) {
        self.reference = reference
        self.title = title
        self.subtitle = subtitle
    }
}

/// Describes which editor the client should use for a live-editable property.
public enum ViewScopeEditableValueKind: String, Codable, Sendable {
    case toggle
    case number
    case text
}

/// v3：数值型可编辑属性的候选值，客户端据此显示下拉框而不是裸数字输入。
public struct ViewScopeEditableOption: Codable, Sendable, Hashable {
    public var title: String
    public var value: Double

    public init(title: String, value: Double) {
        self.title = title
        self.value = value
    }
}

/// Describes a property that can be edited live from the inspector.
public struct ViewScopeEditableProperty: Codable, Sendable, Hashable {
    public var key: String
    public var kind: ViewScopeEditableValueKind
    public var boolValue: Bool?
    public var numberValue: Double?
    public var textValue: String?
    /// v3：枚举候选值；仅 `.number` 使用。
    public var options: [ViewScopeEditableOption]?

    public init(
        key: String,
        kind: ViewScopeEditableValueKind,
        boolValue: Bool? = nil,
        numberValue: Double? = nil,
        textValue: String? = nil,
        options: [ViewScopeEditableOption]? = nil
    ) {
        self.key = key
        self.kind = kind
        self.boolValue = boolValue
        self.numberValue = numberValue
        self.textValue = textValue
        self.options = options
    }

    public static func toggle(key: String, value: Bool) -> ViewScopeEditableProperty {
        ViewScopeEditableProperty(key: key, kind: .toggle, boolValue: value)
    }

    public static func number(key: String, value: Double) -> ViewScopeEditableProperty {
        ViewScopeEditableProperty(key: key, kind: .number, numberValue: value)
    }

    /// v3：带候选项的枚举属性，提交时仍以 `.number` 发送所选 value。
    public static func enumeration(key: String, value: Double, options: [ViewScopeEditableOption]) -> ViewScopeEditableProperty {
        ViewScopeEditableProperty(key: key, kind: .number, numberValue: value, options: options)
    }

    /// 返回只保留“值”的副本（去掉 options），用于发送 mutation。
    public var valueOnly: ViewScopeEditableProperty {
        ViewScopeEditableProperty(key: key, kind: kind, boolValue: boolValue, numberValue: numberValue, textValue: textValue)
    }

    public static func text(key: String, value: String) -> ViewScopeEditableProperty {
        ViewScopeEditableProperty(key: key, kind: .text, textValue: value)
    }
}

public struct ViewScopePropertyItem: Codable, Sendable, Hashable {
    public var title: String
    public var value: String
    public var editable: ViewScopeEditableProperty?

    public init(title: String, value: String, editable: ViewScopeEditableProperty? = nil) {
        self.title = title
        self.value = value
        self.editable = editable
    }
}

public struct ViewScopePropertySection: Codable, Sendable, Hashable {
    public var title: String
    public var items: [ViewScopePropertyItem]

    public init(title: String, items: [ViewScopePropertyItem]) {
        self.title = title
        self.items = items
    }
}

/// Contains the inspector data and preview image for a selected hierarchy node.
public struct ViewScopeNodeDetailPayload: Codable, Sendable, Hashable {
    public var nodeID: String
    public var host: ViewScopeHostInfo
    public var sections: [ViewScopePropertySection]
    public var constraints: [String]
    public var ancestry: [String]
    public var screenshotRootNodeID: String?
    public var screenshotPNGBase64: String?
    public var screenshotSize: ViewScopeSize
    public var highlightedRect: ViewScopeRect
    public var consoleTargets: [ViewScopeConsoleTargetDescriptor]

    public init(
        nodeID: String,
        host: ViewScopeHostInfo,
        sections: [ViewScopePropertySection],
        constraints: [String],
        ancestry: [String],
        screenshotRootNodeID: String? = nil,
        screenshotPNGBase64: String?,
        screenshotSize: ViewScopeSize,
        highlightedRect: ViewScopeRect,
        consoleTargets: [ViewScopeConsoleTargetDescriptor] = []
    ) {
        self.nodeID = nodeID
        self.host = host
        self.sections = sections
        self.constraints = constraints
        self.ancestry = ancestry
        self.screenshotRootNodeID = screenshotRootNodeID
        self.screenshotPNGBase64 = screenshotPNGBase64
        self.screenshotSize = screenshotSize
        self.highlightedRect = highlightedRect
        self.consoleTargets = consoleTargets
    }
}

public struct ViewScopeClientHelloPayload: Codable, Sendable, Hashable {
    public var authToken: String
    public var clientName: String
    public var clientVersion: String
    public var protocolVersion: Int
    public var preferredLanguage: String?

    public init(authToken: String, clientName: String, clientVersion: String, protocolVersion: Int, preferredLanguage: String? = nil) {
        self.authToken = authToken
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
        self.preferredLanguage = preferredLanguage
    }
}

public struct ViewScopeServerHelloPayload: Codable, Sendable, Hashable {
    public var host: ViewScopeHostInfo
    public var protocolVersion: Int

    public init(host: ViewScopeHostInfo, protocolVersion: Int) {
        self.host = host
        self.protocolVersion = protocolVersion
    }
}

public struct ViewScopeNodeRequestPayload: Codable, Sendable, Hashable {
    public var nodeID: String

    public init(nodeID: String) {
        self.nodeID = nodeID
    }
}

public struct ViewScopeHighlightRequestPayload: Codable, Sendable, Hashable {
    public var nodeID: String
    public var duration: Double

    public init(nodeID: String, duration: Double) {
        self.nodeID = nodeID
        self.duration = duration
    }
}

/// Carries a single live-edit mutation request from the client to the host.
public struct ViewScopeMutationRequestPayload: Codable, Sendable, Hashable {
    public var nodeID: String
    public var property: ViewScopeEditableProperty

    public init(nodeID: String, property: ViewScopeEditableProperty) {
        self.nodeID = nodeID
        self.property = property
    }
}

public struct ViewScopeConsoleInvokeRequestPayload: Codable, Sendable, Hashable {
    public var target: ViewScopeRemoteObjectReference
    public var expression: String

    public init(target: ViewScopeRemoteObjectReference, expression: String) {
        self.target = target
        self.expression = expression
    }
}

public struct ViewScopeConsoleInvokeResponsePayload: Codable, Sendable, Hashable {
    public var submittedExpression: String
    public var target: ViewScopeRemoteObjectReference
    public var resultDescription: String?
    public var returnedObject: ViewScopeConsoleTargetDescriptor?
    public var errorMessage: String?

    public init(
        submittedExpression: String,
        target: ViewScopeRemoteObjectReference,
        resultDescription: String? = nil,
        returnedObject: ViewScopeConsoleTargetDescriptor? = nil,
        errorMessage: String? = nil
    ) {
        self.submittedExpression = submittedExpression
        self.target = target
        self.resultDescription = resultDescription
        self.returnedObject = returnedObject
        self.errorMessage = errorMessage
    }
}

/// v3：请求某个 console target 可调用的方法/属性列表，用于自动补全。
public struct ViewScopeConsoleCompletionRequestPayload: Codable, Sendable, Hashable {
    public var target: ViewScopeRemoteObjectReference
    /// 可选前缀过滤；为空时返回全部（服务端会做数量上限）。
    public var prefix: String?

    public init(target: ViewScopeRemoteObjectReference, prefix: String? = nil) {
        self.target = target
        self.prefix = prefix
    }
}

public struct ViewScopeConsoleCompletion: Codable, Sendable, Hashable {
    /// 可直接插入的 selector / 属性名，例如 "setHidden:"、"frame"。
    public var name: String
    /// 便于阅读的签名，例如 "- (void)setHidden:(BOOL)"。
    public var signature: String
    /// 是否为 @property。
    public var isProperty: Bool
    /// 声明该方法的类。
    public var declaringClassName: String

    public init(name: String, signature: String, isProperty: Bool, declaringClassName: String) {
        self.name = name
        self.signature = signature
        self.isProperty = isProperty
        self.declaringClassName = declaringClassName
    }
}

public struct ViewScopeConsoleCompletionResponsePayload: Codable, Sendable, Hashable {
    public var target: ViewScopeRemoteObjectReference
    public var completions: [ViewScopeConsoleCompletion]

    public init(target: ViewScopeRemoteObjectReference, completions: [ViewScopeConsoleCompletion]) {
        self.target = target
        self.completions = completions
    }
}

public struct ViewScopeErrorPayload: Codable, Sendable, Hashable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct ViewScopeAckPayload: Codable, Sendable, Hashable {
    public init() {}
}

/// Wraps every protocol message exchanged between the ViewScope client and host.
public struct ViewScopeMessage: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case clientHello
        case serverHello
        case captureRequest
        case captureResponse
        case nodeDetailRequest
        case nodeDetailResponse
        case highlightRequest
        case mutationRequest
        case consoleInvokeRequest
        case consoleInvokeResponse
        case ack
        case error
        /// v3：无需认证，返回宿主 announcement，用于端口扫描发现。
        case discoveryRequest
        case discoveryResponse
        /// v3：console 自动补全。
        case consoleCompletionRequest
        case consoleCompletionResponse
        /// v3：存活探测，服务端回 ack。
        case ping
    }

    public var kind: Kind
    public var requestID: String?
    public var clientHello: ViewScopeClientHelloPayload?
    public var serverHello: ViewScopeServerHelloPayload?
    public var capture: ViewScopeCapturePayload?
    public var nodeDetail: ViewScopeNodeDetailPayload?
    public var nodeRequest: ViewScopeNodeRequestPayload?
    public var highlightRequest: ViewScopeHighlightRequestPayload?
    public var mutationRequest: ViewScopeMutationRequestPayload?
    public var consoleInvokeRequest: ViewScopeConsoleInvokeRequestPayload?
    public var consoleInvokeResponse: ViewScopeConsoleInvokeResponsePayload?
    public var ack: ViewScopeAckPayload?
    public var error: ViewScopeErrorPayload?
    /// v3：discoveryResponse 携带的宿主信息。
    public var announcement: ViewScopeHostAnnouncement?
    public var consoleCompletionRequest: ViewScopeConsoleCompletionRequestPayload?
    public var consoleCompletionResponse: ViewScopeConsoleCompletionResponsePayload?

    public init(
        kind: Kind,
        requestID: String? = nil,
        clientHello: ViewScopeClientHelloPayload? = nil,
        serverHello: ViewScopeServerHelloPayload? = nil,
        capture: ViewScopeCapturePayload? = nil,
        nodeDetail: ViewScopeNodeDetailPayload? = nil,
        nodeRequest: ViewScopeNodeRequestPayload? = nil,
        highlightRequest: ViewScopeHighlightRequestPayload? = nil,
        mutationRequest: ViewScopeMutationRequestPayload? = nil,
        consoleInvokeRequest: ViewScopeConsoleInvokeRequestPayload? = nil,
        consoleInvokeResponse: ViewScopeConsoleInvokeResponsePayload? = nil,
        ack: ViewScopeAckPayload? = nil,
        error: ViewScopeErrorPayload? = nil,
        announcement: ViewScopeHostAnnouncement? = nil,
        consoleCompletionRequest: ViewScopeConsoleCompletionRequestPayload? = nil,
        consoleCompletionResponse: ViewScopeConsoleCompletionResponsePayload? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.clientHello = clientHello
        self.serverHello = serverHello
        self.capture = capture
        self.nodeDetail = nodeDetail
        self.nodeRequest = nodeRequest
        self.highlightRequest = highlightRequest
        self.mutationRequest = mutationRequest
        self.consoleInvokeRequest = consoleInvokeRequest
        self.consoleInvokeResponse = consoleInvokeResponse
        self.ack = ack
        self.error = error
        self.announcement = announcement
        self.consoleCompletionRequest = consoleCompletionRequest
        self.consoleCompletionResponse = consoleCompletionResponse
    }
}
