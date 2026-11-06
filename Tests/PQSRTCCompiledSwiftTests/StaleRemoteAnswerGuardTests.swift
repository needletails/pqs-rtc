import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC
#endif

/// A late or duplicate answer reaches a peer connection whose signaling is already stable (its offer
/// was answered). Applying it fails with "wrong state", which ends a live call, so both platforms
/// drop it through one guard.
@Suite(.serialized)
struct StaleRemoteAnswerGuardTests {
    /// The Android `setRemote` and `handleAnswer` do not compile on macOS, so they are pinned by source.
    @Test("Android setRemote drops a stale answer and handleAnswer honours the result")
    func androidStaleAnswerIsDroppedThroughSharedGuard() throws {
        let exchange = try source("Sources/PQSRTC/RTCSession+Exchange.swift")

        let androidSetRemote = try SourceContract.sourceBody(
            of: "setRemote(\n        sdp: RTCSessionDescription,",
            in: exchange
        )
        #expect(androidSetRemote.contains("isStaleRemoteAnswer("),
                "Android setRemote has no stable-state guard for answers")
        #expect(androidSetRemote.contains("return .dropped"))

        let appleSetRemote = try SourceContract.sourceBody(
            of: "setRemote(\n        sdp: WebRTC.RTCSessionDescription,",
            in: exchange
        )
        #expect(appleSetRemote.contains("isStaleRemoteAnswer("))

        let handleAnswer = try SourceContract.sourceBody(of: "handleAnswer", in: exchange)
        #expect(!handleAnswer.contains("RemoteDescriptionApplyResult.applied"),
                "Android handleAnswer hard-codes .applied, so a dropped answer still runs post-answer work")
        #expect(handleAnswer.components(separatedBy: "guard remoteApplyResult == .applied else { return }").count - 1 == 1)

        let guardBody = try SourceContract.sourceBody(of: "isStaleRemoteAnswer", in: exchange)
        #expect(guardBody.contains("signalingStateByConnectionId"),
                "Android guard must read the signaling state the peer observer reported")
    }

#if canImport(WebRTC) && !os(Android)
    actor TestTransportEvents: RTCTransportEvents {
        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {}
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
    }

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    @Test("an answer on a stable peer connection is dropped and the call stays live")
    func stableAnswerIsDroppedAndCallStaysLive() async throws {
        let events = TestTransportEvents()
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: events)
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        let call = try Call(sharedCommunicationId: UUID().uuidString, sender: sender, recipients: [recipient])
        try await session.setupCallState(call)
        try await session.startCall(call)

        // A fresh peer connection has no offer outstanding: its signaling state is stable.
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        let identity = try await KeyManager().generateSenderIdentity(
            connectionId: call.sharedCommunicationId,
            secretName: "alice"
        )
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await session.connectionManager.addConnection(RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: call.sharedCommunicationId,
                logger: NeedleTailLogger("[StaleRemoteAnswerGuardTests]"),
                continuation: continuation
            ),
            sender: "alice",
            recipient: "bob",
            localKeys: identity.localKeys,
            symmetricKey: identity.symmetricKey,
            sessionIdentity: identity.sessionIdentity,
            call: call
        ))

        let result = try await session.setRemote(
            sdp: WebRTC.RTCSessionDescription(type: .answer, sdp: "v=0\r\n"),
            call: call
        )
        #expect(result == .dropped)
        #expect(await session.callState.currentState == .connecting(.outbound(.voice), call))
        #expect(await !session.isConnectionFinishingOrEnded(call.sharedCommunicationId))

        await session.shutdown(with: nil)
    }
#endif

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
