import Foundation
import Testing
#if canImport(WebRTC)
import WebRTC
#endif

@testable import PQSRTC

@Suite(.serialized)
struct LiveRejoinMediaReleaseTests {
    actor Transport: RTCTransportEvents {
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

#if canImport(WebRTC) && !os(Android)
    @Test("releasing an ended attempt's media leaves a live same-room rejoin's tracks in place")
    func endedAttemptReleaseKeepsLiveRejoinMedia() async throws {
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "u",
            password: "p",
            delegate: Transport()
        )
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)
        let room = UUID().uuidString
        // A rejoin keeps the room id and gets a new Call.id.
        let endedAttempt = try Call(sharedCommunicationId: room, sender: alice, recipients: [bob], isActive: true)
        let liveAttempt = try Call(sharedCommunicationId: room, sender: alice, recipients: [bob], isActive: true)

        let frameIdentity = try await session.keyManager.generateSenderIdentity(connectionId: room, secretName: "alice")
        _ = try await session.pcKeyManager.generateSenderIdentity(connectionId: room, secretName: "alice")
        let remoteFrame = try await KeyManager().generateSenderIdentity(connectionId: room, secretName: "bob")
        let remoteFrameProps = try #require(await remoteFrame.sessionIdentity.props(symmetricKey: remoteFrame.symmetricKey))
        let remoteSignaling = try await KeyManager().generateSenderIdentity(connectionId: room, secretName: "bob")
        let remoteSignalingProps = try #require(await remoteSignaling.sessionIdentity.props(symmetricKey: remoteSignaling.symmetricKey))
        _ = try await session.keyManager.createRecipientIdentity(connectionId: room, props: remoteFrameProps)
        _ = try await session.pcKeyManager.createRecipientIdentity(connectionId: room, props: remoteSignalingProps)

        await session.callState.transition(to: .connecting(.outbound(.voice), liveAttempt))
        _ = try await session.createPeerConnection(
            with: liveAttempt,
            sender: alice.secretName,
            recipient: bob.secretName,
            localIdentity: frameIdentity
        )
        let before = try #require(await session.connectionManager.findConnection(with: room))
        #expect(before.localAudioTrack != nil)
        #expect(before.peerConnection.senders.contains { $0.track?.kind == kRTCMediaStreamTrackKindAudio })

        // The ended attempt's leftover end path (UI tearDownCall, CallManager.endCall,
        // Android endCall) runs after the rejoin is live.
        await session.releaseLocalMediaResourcesForCallEnding(call: endedAttempt)

        let after = try #require(await session.connectionManager.findConnection(with: room))
        #expect(after.localAudioTrack != nil, "ended attempt's release cleared the live attempt's audio track")
        #expect(after.peerConnection.senders.contains { $0.track?.kind == kRTCMediaStreamTrackKindAudio },
                "ended attempt's release removed the live attempt's audio sender")
        #expect(await session.connectionFallbackStateByConnectionId[room.normalizedConnectionId] != nil,
                "ended attempt's release cleared the live attempt's ICE fallback state")

        await session.shutdown(with: liveAttempt)
    }
#endif
}
