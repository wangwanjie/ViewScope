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
}
