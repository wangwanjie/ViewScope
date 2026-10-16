import Foundation

/// usbmuxd 报告的一台已接入设备（USB 或 Wi-Fi 同步）。
nonisolated struct ViewScopeUSBDevice: Hashable, Sendable, Identifiable {
    /// usbmuxd 本次分配的 DeviceID，重新插拔后会变化。
    var deviceID: Int
    /// 设备序列号（UDID）。
    var serial: String
    /// usbmuxd 报告的连接类型，通常为 "USB" 或 "Network"。
    var connectionType: String
    /// 设备名；usbmuxd 一般不提供，发现宿主后用宿主上报的 deviceName 补全。
    var name: String?
    /// USB ProductID，仅用于展示/调试。
    var productID: Int?

    var id: Int {
        deviceID
    }

    /// 是否通过网络（Wi-Fi 同步）连接。
    var isNetwork: Bool {
        connectionType.caseInsensitiveCompare("Network") == .orderedSame
    }

    /// 本地化的连接方式文案。
    var localizedConnectionType: String {
        if isNetwork {
            return L10n.connectionUSBConnectionTypeNetwork
        }
        return L10n.connectionUSBConnectionTypeUSB
    }

    /// 用于界面展示的设备名，没有名称时回退为通用文案。
    var displayName: String {
        if let name, name.isEmpty == false {
            return name
        }
        return L10n.connectionUSBUnnamedDevice
    }

    init(deviceID: Int, serial: String, connectionType: String, name: String? = nil, productID: Int? = nil) {
        self.deviceID = deviceID
        self.serial = serial
        self.connectionType = connectionType
        self.name = name
        self.productID = productID
    }
}
