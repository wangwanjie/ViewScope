import Foundation

/// 连接与发现相关文案。错误描述可能在后台线程读取，因此统一走 `AppLocalization.backgroundString`。
extension L10n {
    nonisolated static var connectionErrorConnectTimeout: String {
        connectionString("connection.error.connect_timeout")
    }

    nonisolated static var connectionErrorRequestTimeout: String {
        connectionString("connection.error.request_timeout")
    }

    nonisolated static var connectionErrorUnsupportedByHost: String {
        connectionString("connection.error.unsupported_by_host")
    }

    nonisolated static var connectionErrorEncodingFailed: String {
        connectionString("connection.error.encoding_failed")
    }

    nonisolated static var connectionErrorMessageTooLarge: String {
        connectionString("connection.error.message_too_large")
    }

    nonisolated static var connectionErrorInvalidPort: String {
        connectionString("connection.error.invalid_port")
    }

    nonisolated static var connectionErrorNotConnected: String {
        connectionString("connection.error.not_connected")
    }

    nonisolated static var connectionErrorMissingDevice: String {
        connectionString("connection.error.missing_device")
    }

    nonisolated static func connectionErrorUSBMuxUnavailable(_ reason: String) -> String {
        connectionString("connection.error.usbmux_unavailable", reason)
    }

    nonisolated static func connectionErrorUSBMuxRefused(_ code: Int) -> String {
        connectionString("connection.error.usbmux_refused", code)
    }

    nonisolated static var connectionErrorUSBMuxProtocol: String {
        connectionString("connection.error.usbmux_protocol")
    }

    nonisolated static var connectionErrorTransportTimeout: String {
        connectionString("connection.error.transport_timeout")
    }

    nonisolated static var connectionUSBConnectionTypeUSB: String {
        connectionString("connection.usb.connection_type.usb")
    }

    nonisolated static var connectionUSBConnectionTypeNetwork: String {
        connectionString("connection.usb.connection_type.network")
    }

    nonisolated static var connectionUSBUnnamedDevice: String {
        connectionString("connection.usb.unnamed_device")
    }

    nonisolated private static func connectionString(_ key: String, _ arguments: CVarArg...) -> String {
        AppLocalization.backgroundString(key, arguments: arguments)
    }
}
