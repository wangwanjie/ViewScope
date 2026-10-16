import Foundation

/// usbmuxd plist 协议的报文编解码。
///
/// 报文格式：16 字节小端头部（length、version、message、tag），后接 XML plist。
/// - length：整个报文长度（含头部）；
/// - version：1（plist 协议）；
/// - message：8（plist）；
/// - tag：请求方自增，响应原样带回。
nonisolated enum ViewScopeUSBMuxPacket {
    static let headerLength = 16
    static let plistVersion: UInt32 = 1
    static let plistMessageType: UInt32 = 8
    /// 单个报文的上限，防止异常数据导致无限缓存。
    static let maximumPacketLength = 16 * 1024 * 1024
    /// usbmuxd 默认 socket 路径。
    static let defaultSocketPath = "/var/run/usbmuxd"

    struct Header: Equatable, Sendable {
        var length: UInt32
        var version: UInt32
        var messageType: UInt32
        var tag: UInt32
    }

    /// 一个完整报文。
    struct Packet {
        var header: Header
        var payload: [String: Any]
    }

    // MARK: - 编码

    /// 把 plist 字典编码为完整报文。
    static func encode(payload: [String: Any], tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var data = Data(capacity: headerLength + body.count)
        appendLittleEndian(UInt32(headerLength + body.count), to: &data)
        appendLittleEndian(plistVersion, to: &data)
        appendLittleEndian(plistMessageType, to: &data)
        appendLittleEndian(tag, to: &data)
        data.append(body)
        return data
    }

    /// 解析 16 字节头部；数据不足时返回 nil。
    static func decodeHeader(_ data: Data) -> Header? {
        guard data.count >= headerLength else {
            return nil
        }
        let start = data.startIndex
        return Header(
            length: readLittleEndian(data, at: start),
            version: readLittleEndian(data, at: start + 4),
            messageType: readLittleEndian(data, at: start + 8),
            tag: readLittleEndian(data, at: start + 12)
        )
    }

    /// 解析报文体。
    static func decodePayload(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw ViewScopeTransportError.usbmuxProtocol
        }
        return dictionary
    }

    // MARK: - 请求

    /// 公共字段。
    private static func basePayload(messageType: String) -> [String: Any] {
        [
            "MessageType": messageType,
            "ClientVersionString": "ViewScope",
            "ProgName": "ViewScope",
            "kLibUSBMuxVersion": 3
        ]
    }

    static func listDevicesPayload() -> [String: Any] {
        basePayload(messageType: "ListDevices")
    }

    static func listenPayload() -> [String: Any] {
        basePayload(messageType: "Listen")
    }

    /// Connect 请求。PortNumber 需要是网络字节序（等同 htons）。
    static func connectPayload(deviceID: Int, port: UInt16) -> [String: Any] {
        var payload = basePayload(messageType: "Connect")
        payload["DeviceID"] = deviceID
        payload["PortNumber"] = Int(networkOrderPort(port))
        return payload
    }

    /// 把主机字节序端口转换为 usbmuxd 期望的网络字节序数值。
    static func networkOrderPort(_ port: UInt16) -> UInt16 {
        port.bigEndian
    }

    // MARK: - 响应解析

    /// `Result` 报文中的 Number；不是 Result 报文时返回 nil。
    static func resultNumber(in payload: [String: Any]) -> Int? {
        guard (payload["MessageType"] as? String) == "Result" else {
            return nil
        }
        return (payload["Number"] as? NSNumber)?.intValue
    }

    /// 从 Attached 报文（或 DeviceList 中的元素）解析设备。
    static func device(from payload: [String: Any]) -> ViewScopeUSBDevice? {
        let properties = payload["Properties"] as? [String: Any] ?? [:]
        let deviceIDNumber = (payload["DeviceID"] as? NSNumber) ?? (properties["DeviceID"] as? NSNumber)
        guard let deviceID = deviceIDNumber?.intValue,
              let serial = properties["SerialNumber"] as? String,
              serial.isEmpty == false else {
            return nil
        }
        let connectionType = properties["ConnectionType"] as? String ?? "USB"
        let name = properties["DeviceName"] as? String
        let productID = (properties["ProductID"] as? NSNumber)?.intValue
        return ViewScopeUSBDevice(
            deviceID: deviceID,
            serial: serial,
            connectionType: connectionType,
            name: name,
            productID: productID
        )
    }

    /// ListDevices 响应中的设备列表。
    static func devices(fromDeviceList payload: [String: Any]) -> [ViewScopeUSBDevice] {
        guard let list = payload["DeviceList"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            device(from: entry)
        }
    }

    /// Detached 报文中的 DeviceID。
    static func detachedDeviceID(from payload: [String: Any]) -> Int? {
        guard (payload["MessageType"] as? String) == "Detached" else {
            return nil
        }
        return (payload["DeviceID"] as? NSNumber)?.intValue
    }

    // MARK: - 字节序工具

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func readLittleEndian(_ data: Data, at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 {
            value |= UInt32(data[index + offset]) << (8 * UInt32(offset))
        }
        return value
    }
}

/// usbmuxd 报文流的分帧器：按头部 length 切分完整报文。
nonisolated struct ViewScopeUSBMuxPacketFramer {
    private var buffer = Data()

    /// 追加数据并返回所有完整报文；遇到非法头部时抛错。
    mutating func append(_ data: Data) throws -> [ViewScopeUSBMuxPacket.Packet] {
        buffer.append(data)
        var packets: [ViewScopeUSBMuxPacket.Packet] = []
        while let header = ViewScopeUSBMuxPacket.decodeHeader(buffer) {
            let length = Int(header.length)
            guard length >= ViewScopeUSBMuxPacket.headerLength,
                  length <= ViewScopeUSBMuxPacket.maximumPacketLength else {
                buffer = Data()
                throw ViewScopeTransportError.usbmuxProtocol
            }
            guard buffer.count >= length else {
                break
            }
            let start = buffer.startIndex
            let body = buffer.subdata(in: (start + ViewScopeUSBMuxPacket.headerLength)..<(start + length))
            buffer = buffer.subdata(in: (start + length)..<buffer.endIndex)
            packets.append(ViewScopeUSBMuxPacket.Packet(header: header, payload: try ViewScopeUSBMuxPacket.decodePayload(body)))
        }
        return packets
    }
}
