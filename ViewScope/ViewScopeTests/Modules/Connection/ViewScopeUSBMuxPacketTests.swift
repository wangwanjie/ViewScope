import Foundation
import Testing
@testable import ViewScope

struct ViewScopeUSBMuxPacketTests {
    @Test func encodeWritesLittleEndianHeaderAndXMLPlist() throws {
        let data = try ViewScopeUSBMuxPacket.encode(payload: ViewScopeUSBMuxPacket.listenPayload(), tag: 7)

        let header = try #require(ViewScopeUSBMuxPacket.decodeHeader(data))
        #expect(Int(header.length) == data.count)
        #expect(header.version == 1)
        #expect(header.messageType == 8)
        #expect(header.tag == 7)
        // 头部逐字节为小端：length 的最低字节在最前
        #expect(data[0] == UInt8(data.count & 0xFF))
        #expect(data[4] == 1 && data[5] == 0 && data[6] == 0 && data[7] == 0)
        #expect(data[8] == 8)
        #expect(data[12] == 7)

        let body = data.subdata(in: ViewScopeUSBMuxPacket.headerLength..<data.count)
        #expect(String(decoding: body.prefix(5), as: UTF8.self) == "<?xml")
        let payload = try ViewScopeUSBMuxPacket.decodePayload(body)
        #expect(payload["MessageType"] as? String == "Listen")
    }

    @Test func connectPayloadUsesNetworkByteOrderPort() throws {
        let payload = ViewScopeUSBMuxPacket.connectPayload(deviceID: 5, port: 47300)
        #expect(payload["MessageType"] as? String == "Connect")
        #expect((payload["DeviceID"] as? Int) == 5)
        // 47300 = 0xB8C4，htons 后为 0xC4B8 = 50360
        #expect((payload["PortNumber"] as? Int) == 0xC4B8)
        #expect(ViewScopeUSBMuxPacket.networkOrderPort(0x1234) == 0x3412)
    }

    @Test func resultNumberParsing() {
        #expect(ViewScopeUSBMuxPacket.resultNumber(in: ["MessageType": "Result", "Number": 0]) == 0)
        #expect(ViewScopeUSBMuxPacket.resultNumber(in: ["MessageType": "Result", "Number": 3]) == 3)
        #expect(ViewScopeUSBMuxPacket.resultNumber(in: ["MessageType": "Attached"]) == nil)
    }

    @Test func framerReassemblesPacketsAcrossChunks() throws {
        let attached: [String: Any] = [
            "MessageType": "Attached",
            "DeviceID": 12,
            "Properties": [
                "SerialNumber": "00008030-ABC",
                "ConnectionType": "USB",
                "DeviceID": 12,
                "ProductID": 4776
            ]
        ]
        let detached: [String: Any] = ["MessageType": "Detached", "DeviceID": 12]
        var stream = try ViewScopeUSBMuxPacket.encode(payload: attached, tag: 0)
        stream.append(try ViewScopeUSBMuxPacket.encode(payload: detached, tag: 0))

        var framer = ViewScopeUSBMuxPacketFramer()
        let splitIndex = 10
        let partial = try framer.append(stream.subdata(in: 0..<splitIndex))
        #expect(partial.isEmpty)
        let packets = try framer.append(stream.subdata(in: splitIndex..<stream.count))
        #expect(packets.count == 2)

        let device = try #require(ViewScopeUSBMuxPacket.device(from: packets[0].payload))
        #expect(device.deviceID == 12)
        #expect(device.serial == "00008030-ABC")
        #expect(device.connectionType == "USB")
        #expect(device.productID == 4776)
        #expect(device.isNetwork == false)
        #expect(ViewScopeUSBMuxPacket.detachedDeviceID(from: packets[1].payload) == 12)
    }

    @Test func framerRejectsInvalidLength() {
        var header = Data()
        // length = 4（小于头部长度），非法
        header.append(contentsOf: [4, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0])
        var framer = ViewScopeUSBMuxPacketFramer()
        #expect(throws: ViewScopeTransportError.self) {
            _ = try framer.append(header)
        }
    }

    @Test func deviceListParsing() {
        let payload: [String: Any] = [
            "DeviceList": [
                ["DeviceID": 1, "Properties": ["SerialNumber": "A", "ConnectionType": "USB"]],
                ["DeviceID": 2, "Properties": ["SerialNumber": "A", "ConnectionType": "Network"]],
                ["DeviceID": 3, "Properties": [:] as [String: Any]]
            ]
        ]
        let devices = ViewScopeUSBMuxPacket.devices(fromDeviceList: payload)
        #expect(devices.map(\.deviceID) == [1, 2])
        #expect(devices[1].isNetwork)
    }
}
