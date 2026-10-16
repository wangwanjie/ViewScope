import Foundation
import ViewScopeServer

/// 客户端统一的 JSON 编解码配置（日期使用 ISO8601，与服务端一致）。
nonisolated enum ViewScopeConnectionCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 把消息编码为一行（末尾追加换行符）。
    static func encodeLine(_ message: ViewScopeMessage, encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }
}

/// 按换行符切分的分帧器，缓冲区有上限，避免对端只发数据不发换行时无限增长。
nonisolated struct ViewScopeLineFramer {
    enum FramingError: Error {
        /// 未分帧的数据超过上限。
        case bufferOverflow
    }

    /// 默认上限 256MB（单个 capture 可能包含较多位图）。
    static let defaultMaximumBufferSize = 256 * 1024 * 1024

    let maximumBufferSize: Int
    private var buffer = Data()
    /// buffer 中已确认不含换行符的前缀长度，避免大消息分多次到达时重复扫描。
    private var scannedCount = 0

    init(maximumBufferSize: Int = ViewScopeLineFramer.defaultMaximumBufferSize) {
        self.maximumBufferSize = maximumBufferSize
    }

    /// 当前缓存的未完成数据长度。
    var bufferedByteCount: Int {
        buffer.count
    }

    /// 追加数据并返回其中所有完整的行（不含换行符，跳过空行）。
    mutating func append(_ data: Data) throws -> [Data] {
        if data.isEmpty == false {
            buffer.append(data)
        }
        var lines: [Data] = []
        var consumed = 0
        let total = buffer.count
        let searchOrigin = scannedCount
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                return
            }
            var searchStart = searchOrigin
            while searchStart < total {
                // memchr 比逐字节遍历 Data 快得多，大 capture 时效果明显
                guard let found = memchr(base + searchStart, 0x0A, total - searchStart) else {
                    break
                }
                let index = base.distance(to: UnsafeRawPointer(found))
                if index > consumed {
                    lines.append(Data(bytes: base + consumed, count: index - consumed))
                }
                consumed = index + 1
                searchStart = consumed
            }
        }
        if consumed > 0 {
            buffer = consumed < total ? buffer.subdata(in: consumed..<total) : Data()
        }
        scannedCount = buffer.count
        if buffer.count > maximumBufferSize {
            buffer = Data()
            scannedCount = 0
            throw FramingError.bufferOverflow
        }
        return lines
    }
}

/// 把原始字节流解码为 `ViewScopeMessage`。在 transport 的后台串行队列上使用，避免大 payload 解码卡主线程。
nonisolated final class ViewScopeMessageStreamDecoder: @unchecked Sendable {
    enum Output: Sendable {
        case message(ViewScopeMessage)
        /// 一行无法解码；尽量从中取出 requestID，用于让对应请求失败。
        case undecodable(requestID: String?)
        /// 缓冲区超过上限，连接已不可用。
        case overflow
    }

    private var framer: ViewScopeLineFramer
    private let decoder = ViewScopeConnectionCoding.makeDecoder()

    init(maximumBufferSize: Int = ViewScopeLineFramer.defaultMaximumBufferSize) {
        framer = ViewScopeLineFramer(maximumBufferSize: maximumBufferSize)
    }

    /// 注意：同一实例只能在一个串行队列上调用。
    func consume(_ data: Data) -> [Output] {
        let lines: [Data]
        do {
            lines = try framer.append(data)
        } catch {
            return [.overflow]
        }
        return lines.map { line in
            decode(line)
        }
    }

    private func decode(_ line: Data) -> Output {
        do {
            return .message(try decoder.decode(ViewScopeMessage.self, from: line))
        } catch {
            return .undecodable(requestID: Self.extractRequestID(from: line))
        }
    }

    /// 用 JSONSerialization 宽松地取出 requestID。
    static func extractRequestID(from line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line, options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary["requestID"] as? String
    }
}
