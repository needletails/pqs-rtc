import Foundation
import Testing
import NeedleTailLogger
@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

@Suite(.serialized)
struct RTCConnectionManagerTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func makeCall(sharedId: String) throws -> Call {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        return try Call(sharedCommunicationId: sharedId, sender: sender, recipients: [recipient])
    }

    private func makeConnection(id: String, recipient: String) async throws -> RTCConnection {
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(connectionId: id, secretName: "alice")

        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream // we only need the continuation for wrapper construction

        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: id,
            logger: NeedleTailLogger("[test]"),
            continuation: continuation
        )

        return RTCConnection(
            id: id,
            peerConnection: try makePeerConnection(),
            delegateWrapper: delegateWrapper,
            sender: "alice",
            recipient: recipient,
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: try makeCall(sharedId: id)
        )
    }

    @Test
    func addAndFindConnectionById() async throws {
        let manager = RTCConnectionManager(logger: NeedleTailLogger("[test]"))
        let conn = try await makeConnection(id: "c1", recipient: "bob")

        await manager.addConnection(conn)

        let found = await manager.findConnection(with: "c1")
        #expect(found != nil)
        #expect(found?.id == "c1")
        #expect(found?.recipient == "bob")
    }

    @Test
    func addConnectionReplacesExistingWithSameId() async throws {
        let manager = RTCConnectionManager(logger: NeedleTailLogger("[test]"))

        let first = try await makeConnection(id: "c1", recipient: "bob")
        let second = try await makeConnection(id: "c1", recipient: "carol")

        await manager.addConnection(first)
        await manager.addConnection(second)

        let found = await manager.findConnection(with: "c1")
        #expect(found != nil)
        #expect(found?.recipient == "carol")

        let all = await manager.findAllConnections()
        #expect(all.count == 1)
    }

    @Test
    func updateConnectionReplacesStoredValue() async throws {
        let manager = RTCConnectionManager(logger: NeedleTailLogger("[test]"))

        let first = try await makeConnection(id: "c1", recipient: "bob")
        await manager.addConnection(first)

        let updated = try await makeConnection(id: "c1", recipient: "dave")
        await manager.updateConnection(id: "c1", with: updated)

        let found = await manager.findConnection(with: "c1")
        #expect(found?.recipient == "dave")
    }

    @Test
    func removeConnectionAndRemoveAllConnections() async throws {
        let manager = RTCConnectionManager(logger: NeedleTailLogger("[test]"))

        let c1 = try await makeConnection(id: "c1", recipient: "bob")
        let c2 = try await makeConnection(id: "c2", recipient: "carol")

        await manager.addConnection(c1)
        await manager.addConnection(c2)

        await manager.removeConnection(with: "c1")
        #expect(await manager.findConnection(with: "c1") == nil)
        #expect(await manager.findConnection(with: "c2") != nil)

        await manager.removeAllConnections()
        #expect(await manager.findAllConnections().isEmpty)
    }

    @Test
    func findConnectionIdByPeerConnectionIdentity() async throws {
        let manager = RTCConnectionManager(logger: NeedleTailLogger("[test]"))
        let conn = try await makeConnection(id: "c1", recipient: "bob")

        await manager.addConnection(conn)

        let foundId = await manager.findConnectionId(for: conn.peerConnection)
        #expect(foundId == "c1")
    }
}
#endif
