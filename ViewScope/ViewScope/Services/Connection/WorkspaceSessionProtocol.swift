import Foundation
import ViewScopeServer

@MainActor
protocol WorkspaceSessionProtocol: AnyObject {
    var announcement: ViewScopeHostAnnouncement { get }
    func open() async throws -> ViewScopeServerHelloPayload
    func requestCapture() async throws -> ViewScopeCapturePayload
    func requestNodeDetail(nodeID: String) async throws -> ViewScopeNodeDetailPayload
    func highlight(nodeID: String, duration: TimeInterval) async throws
    func applyMutation(nodeID: String, property: ViewScopeEditableProperty) async throws
    func invokeConsole(
        target: ViewScopeRemoteObjectReference,
        expression: String
    ) async throws -> ViewScopeConsoleInvokeResponsePayload
    func disconnect()

    /// 握手完成后服务端实际协议版本；未握手或旧宿主时为 2。
    var negotiatedProtocolVersion: Int { get }
    /// 注册“连接意外断开”回调（主动调用 `disconnect()` 不会触发）。
    func setUnexpectedDisconnectHandler(_ handler: (@MainActor (Error) -> Void)?)
    /// v3：请求 console 补全列表；旧宿主抛出不支持错误。
    func requestConsoleCompletions(
        target: ViewScopeRemoteObjectReference,
        prefix: String?
    ) async throws -> [ViewScopeConsoleCompletion]
    /// v3：存活探测（服务端回 ack）；旧宿主抛出不支持错误。
    func ping() async throws
}

/// 默认实现，保证测试用的 mock session 不必实现 v3 新增能力。
extension WorkspaceSessionProtocol {
    var negotiatedProtocolVersion: Int {
        viewScopeMinimumSupportedProtocolVersion
    }

    func setUnexpectedDisconnectHandler(_ handler: (@MainActor (Error) -> Void)?) {
        _ = handler
    }

    func requestConsoleCompletions(
        target: ViewScopeRemoteObjectReference,
        prefix: String?
    ) async throws -> [ViewScopeConsoleCompletion] {
        _ = target
        _ = prefix
        return []
    }

    func ping() async throws {
    }
}
