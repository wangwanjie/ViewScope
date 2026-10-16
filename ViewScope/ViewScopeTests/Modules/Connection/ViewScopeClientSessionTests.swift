import Foundation
import Testing
import ViewScopeServer
@testable import ViewScope

@Suite(.serialized)
@MainActor
struct ViewScopeClientSessionTests {
    private typealias SessionError = ViewScopeClientSession.SessionError

    /// 自动回复 clientHello 的 responder。
    private static func helloResponder(serverVersion: Int) -> @Sendable (ViewScopeMessage, FakeByteTransport) -> Void {
        { message, transport in
            guard message.kind == .clientHello else {
                return
            }
            let hello = ViewScopeServerHelloPayload(
                host: ConnectionTestFixtures.hostInfo(protocolVersion: serverVersion),
                protocolVersion: serverVersion
            )
            transport.deliver(ViewScopeMessage(kind: .serverHello, requestID: message.requestID, serverHello: hello))
        }
    }

    private func makeSession(
        announcement: ViewScopeHostAnnouncement = ConnectionTestFixtures.announcement(),
        transport: FakeByteTransport,
        timeouts: ViewScopeSessionTimeouts = .standard
    ) -> ViewScopeClientSession {
        ViewScopeClientSession(announcement: announcement, timeouts: timeouts) { _ in
            transport
        }
    }

    @Test func openNegotiatesProtocolVersionWithV3Host() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)

        _ = try await session.open()

        #expect(transport.sentMessages.first?.clientHello?.protocolVersion == 3)
        #expect(session.negotiatedProtocolVersion == 3)
    }

    @Test func openDowngradesForV2HostAndRejectsV3Requests() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 2)
        let session = makeSession(
            announcement: ConnectionTestFixtures.announcement(protocolVersion: 2),
            transport: transport
        )

        _ = try await session.open()

        #expect(transport.sentMessages.first?.clientHello?.protocolVersion == 2)
        #expect(session.negotiatedProtocolVersion == 2)
        await #expect(throws: SessionError.unsupportedByHost) {
            _ = try await session.requestConsoleCompletions(target: ConnectionTestFixtures.target(), prefix: nil)
        }
        await #expect(throws: SessionError.unsupportedByHost) {
            try await session.ping()
        }
        // 旧宿主不应收到 v3 消息
        #expect(transport.sentMessages.count == 1)
    }

    @Test func responsesAreMatchedByRequestIDOutOfOrder() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)
        _ = try await session.open()

        async let first = session.requestNodeDetail(nodeID: "node-a")
        async let second = session.requestNodeDetail(nodeID: "node-b")

        let allSent = await connectionTestWait {
            transport.sentMessages.count == 3
        }
        #expect(allSent)
        let requests = transport.sentMessages.filter { $0.kind == .nodeDetailRequest }
        // 倒序回复
        for request in requests.reversed() {
            let nodeID = request.nodeRequest?.nodeID ?? ""
            transport.deliver(
                ViewScopeMessage(
                    kind: .nodeDetailResponse,
                    requestID: request.requestID,
                    nodeDetail: ConnectionTestFixtures.detail(nodeID: nodeID)
                )
            )
        }

        let results = try await (first, second)
        #expect(results.0.nodeID == "node-a")
        #expect(results.1.nodeID == "node-b")
    }

    @Test func requestTimesOutWithoutDroppingConnection() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(
            transport: transport,
            timeouts: ViewScopeSessionTimeouts(connect: 1, request: 0.1, capture: 0.1)
        )
        _ = try await session.open()

        await #expect(throws: SessionError.timedOut) {
            _ = try await session.requestNodeDetail(nodeID: "slow")
        }

        // 迟到的响应被丢弃，不会崩溃
        let lateRequest = transport.sentMessages.last
        transport.deliver(
            ViewScopeMessage(
                kind: .nodeDetailResponse,
                requestID: lateRequest?.requestID,
                nodeDetail: ConnectionTestFixtures.detail(nodeID: "slow")
            )
        )

        // 连接仍可用：下一条请求正常完成
        transport.responder = { message, transport in
            guard message.kind == .ping else {
                return
            }
            transport.deliver(ViewScopeMessage(kind: .ack, requestID: message.requestID, ack: ViewScopeAckPayload()))
        }
        try await session.ping()
        #expect(transport.cancelCount == 0)
    }

    @Test func connectTimesOutWhenTransportNeverBecomesReady() async throws {
        let transport = FakeByteTransport(autoReady: false)
        let session = makeSession(
            transport: transport,
            timeouts: ViewScopeSessionTimeouts(connect: 0.1, request: 1, capture: 1)
        )

        await #expect(throws: SessionError.connectTimedOut) {
            _ = try await session.open()
        }
        #expect(transport.cancelCount >= 1)
    }

    @Test func connectFailsFastWhenTransportCloses() async throws {
        let transport = FakeByteTransport(autoReady: false)
        let session = makeSession(transport: transport)

        async let opening: ViewScopeServerHelloPayload = session.open()
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.emit(.closed(ViewScopeTransportError.posix(ECONNREFUSED)))

        do {
            _ = try await opening
            Issue.record("open 应该失败")
        } catch let error as SessionError {
            guard case .connectionFailed = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test func undecodableReplyFailsMatchingRequest() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)
        _ = try await session.open()

        transport.responder = { message, transport in
            guard message.kind == .captureRequest, let requestID = message.requestID else {
                return
            }
            // 合法 JSON 但不是合法的 ViewScopeMessage
            transport.deliverRaw("{\"requestID\":\"\(requestID)\",\"kind\":\"unknownKind\"}\n")
        }

        await #expect(throws: SessionError.invalidResponse) {
            _ = try await session.requestCapture()
        }
    }

    @Test func serverErrorIsSurfaced() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)
        _ = try await session.open()

        transport.responder = { message, transport in
            guard message.kind == .mutationRequest else {
                return
            }
            transport.deliver(
                ViewScopeMessage(kind: .error, requestID: message.requestID, error: ViewScopeErrorPayload(message: "boom"))
            )
        }

        await #expect(throws: SessionError.server("boom")) {
            try await session.applyMutation(nodeID: "n", property: .toggle(key: "hidden", value: true))
        }
    }

    @Test func unexpectedDisconnectNotifiesHandlerAndFailsPending() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)
        _ = try await session.open()

        var receivedErrors: [Error] = []
        session.setUnexpectedDisconnectHandler { error in
            receivedErrors.append(error)
        }

        let pending = Task {
            try await session.requestCapture()
        }
        let sent = await connectionTestWait {
            transport.sentMessages.count == 2
        }
        #expect(sent)
        transport.emit(.closed(nil))

        await #expect(throws: SessionError.disconnected) {
            _ = try await pending.value
        }
        #expect(receivedErrors.count == 1)
        #expect((receivedErrors.first as? SessionError) == .disconnected)
    }

    @Test func manualDisconnectDoesNotNotifyHandler() async throws {
        let transport = FakeByteTransport()
        transport.responder = Self.helloResponder(serverVersion: 3)
        let session = makeSession(transport: transport)
        _ = try await session.open()

        var notified = false
        session.setUnexpectedDisconnectHandler { _ in
            notified = true
        }
        session.disconnect()
        transport.emit(.closed(nil))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(notified == false)
        await #expect(throws: SessionError.disconnected) {
            try await session.ping()
        }
    }

    @Test func loopbackTransportFailsFastOnClosedPort() async throws {
        // 端口 1 在本机上通常未监听：NWConnection 会进入 waiting，transport 应立即失败而不是等到超时
        let session = ViewScopeClientSession(
            announcement: ConnectionTestFixtures.announcement(port: 1),
            timeouts: ViewScopeSessionTimeouts(connect: 5, request: 1, capture: 1)
        )
        let start = Date()
        do {
            _ = try await session.open()
            Issue.record("open 应该失败")
        } catch let error as SessionError {
            #expect(error != .connectTimedOut)
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }
}

/// 分帧与解码管线测试。
struct ViewScopeMessageStreamTests {
    @Test func framerSplitsLinesAcrossChunks() throws {
        var framer = ViewScopeLineFramer(maximumBufferSize: 1024)
        let partial = try framer.append(Data("abc".utf8))
        #expect(partial.isEmpty)
        let lines = try framer.append(Data("def\n\nghi\njk".utf8))
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["abcdef", "ghi"])
        #expect(framer.bufferedByteCount == 2)
        let tail = try framer.append(Data("\n".utf8))
        #expect(tail.map { String(decoding: $0, as: UTF8.self) } == ["jk"])
        #expect(framer.bufferedByteCount == 0)
    }

    @Test func framerRejectsOversizedBuffer() {
        var framer = ViewScopeLineFramer(maximumBufferSize: 8)
        #expect(throws: ViewScopeLineFramer.FramingError.self) {
            _ = try framer.append(Data(repeating: 0x41, count: 16))
        }
    }

    @Test func decoderExtractsRequestIDFromInvalidMessage() {
        let decoder = ViewScopeMessageStreamDecoder(maximumBufferSize: 1024)
        let outputs = decoder.consume(Data("{\"requestID\":\"abc\",\"kind\":42}\n".utf8))
        guard case .undecodable(let requestID)? = outputs.first else {
            Issue.record("应得到 undecodable")
            return
        }
        #expect(requestID == "abc")
    }
}
