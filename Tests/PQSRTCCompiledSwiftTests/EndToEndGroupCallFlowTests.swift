import Foundation
import Testing
import BinaryCodable
import DoubleRatchetKit
import Crypto
import Dispatch
#if canImport(WebRTC)
import WebRTC
#endif

@testable import PQSRTC

@Suite(.serialized)
struct EndToEndGroupCallFlowTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [(call: Call, sfuRecipientId: String)] = []
        private(set) var sfuMessages: [(packet: RatchetMessagePacket, call: Call)] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
            sfuMessages.append((packet: packet, call: call))
        }
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}

        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {
            negotiated.append((call: call, sfuRecipientId: sfuRecipientId))
        }

        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    private func waitUntil(
        timeoutSeconds: Double = 2.0,
        pollEveryMs: UInt64 = 10,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: pollEveryMs * 1_000_000)
        }
        return await predicate()
    }
    
    private func step(_ name: String, _ block: @escaping () async throws -> Void) async throws {
        do {
            try await block()
        } catch {
            Issue.record("Step '\(name)' failed: \(error)")
            throw error
        }
    }

    @Test
    func groupCall_sends_encrypted_offer_and_candidates() async throws {
        let transport = Transport()
        // WebRTC requires at least one ICE server entry (even if not contacted in unit tests).
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"

        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        let carol = try Call.Participant(secretName: "carol", nickname: "Carol", deviceId: "carol-device")

        // Join group call. This should trigger negotiateGroupIdentity on transport.
        try await step("join") {
            try await session.join(sender: local, participants: [bob, carol], sfuRecipientId: sfuRecipientId)
        }
        let negotiated = await waitUntil {
            await transport.negotiated.isEmpty == false
        }
        #expect(negotiated, "Expected negotiateGroupIdentity to be called during join()")
        let negotiatedCall = await transport.negotiated.last!.call
        guard let clientProps = negotiatedCall.signalingIdentityProps else {
            Issue.record("Expected join() to include local signalingIdentityProps in negotiateGroupIdentity(call:...)")
            return
        }

        // SFU identity (server-side): generate once and use its props for the client,
        // so client->SFU packets can be decrypted by the SFU harness.
        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sfuRecipientId,
            secretName: sfuRecipientId
        )
        guard let sfuProps = await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey) else {
            Issue.record("Missing SFU identity props")
            return
        }
        let sfuExecutor = RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.ratchet"))
        let sfuRatchet = DoubleRatchetStateManager<SHA256>(executor: sfuExecutor)

        // Call used to create SFU identity and start the SFU peer connection/offer.
        var call = try Call(sharedCommunicationId: sfuRecipientId, sender: local, recipients: [bob, carol], supportsVideo: false)
        call.signalingIdentityProps = sfuProps

        try await step("createSFUIdentity/startGroupCall(encrypt offer)") {
            try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
        }

        let gotOffer = await waitUntil { await transport.sfuMessages.contains(where: { $0.packet.flag == .offer }) }
        #expect(gotOffer, "Expected encrypted SFU offer packet to be sent")
        let offerPacket = await transport.sfuMessages.last(where: { $0.packet.flag == .offer })!.packet
        #expect(offerPacket.sfuIdentity == sfuRecipientId)
        #expect(offerPacket.ratchetMessage.header.headerCiphertext.isEmpty == false)
        
        // --- SFU-side decrypt validation (client -> SFU) ---
        // Receiver initializes from header and decrypts the offer payload.
        try await step("SFU decrypt offer") {
            try await sfuRatchet.recipientInitialization(
            sessionIdentity: sfuLocalIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            header: offerPacket.header,
            localKeys: sfuLocalIdentity.localKeys
            )
        }
        let decryptedOfferBytes = try await sfuRatchet.ratchetDecrypt(
            offerPacket.ratchetMessage,
            sessionId: sfuLocalIdentity.sessionIdentity.id
        )
        let decryptedOfferCall = try BinaryDecoder().decode(Call.self, from: decryptedOfferBytes)
        #expect(decryptedOfferCall.sharedCommunicationId == sfuRecipientId)
        guard let decryptedOfferMetadata = decryptedOfferCall.metadata else {
            Issue.record("Decrypted offer call missing metadata (expected SessionDescription)")
            return
        }
        _ = try BinaryDecoder().decode(SessionDescription.self, from: decryptedOfferMetadata)

        // Allow candidate sending, then inject a generated ICE candidate notification.
        try await step("startSendingCandidates") {
            try await session.startSendingCandidates(call: call)
        }
        await session.peerConnectionNotificationsContinuation.yield(
            .generatedIceCandidate(sfuRecipientId, "candidate: 1 1 UDP 1234 1.2.3.4 9999 typ host", 0, "0")
        )

        let gotCandidate = await waitUntil { await transport.sfuMessages.contains(where: { $0.packet.flag == .candidate }) }
        #expect(gotCandidate, "Expected encrypted SFU candidate packet to be sent")
        let candidatePacket = await transport.sfuMessages.last(where: { $0.packet.flag == .candidate })!.packet
        #expect(candidatePacket.sfuIdentity == sfuRecipientId)
        #expect(candidatePacket.ratchetMessage.header.headerCiphertext.isEmpty == false)
        
        // Decrypt the candidate on the SFU side and verify payload contains an IceCandidate.
        // For subsequent messages, do not re-run recipientInitialization; let the ratchet state advance naturally.
        let decryptedCandidateBytes = try await sfuRatchet.ratchetDecrypt(
            candidatePacket.ratchetMessage,
            sessionId: sfuLocalIdentity.sessionIdentity.id
        )
        let decryptedCandidateCall = try BinaryDecoder().decode(Call.self, from: decryptedCandidateBytes)
        guard let decryptedCandidateMetadata = decryptedCandidateCall.metadata else {
            Issue.record("Decrypted candidate call missing metadata (expected IceCandidate)")
            return
        }
        let decryptedIce = try BinaryDecoder().decode(IceCandidate.self, from: decryptedCandidateMetadata)
        #expect(decryptedIce.sdp.contains("candidate:"))
        
        // --- Client-side decrypt validation (SFU -> client) ---
        // Initialize SFU sender state so it can encrypt to the client.
        try await step("SFU senderInitialization") {
            try await sfuRatchet.senderInitialization(
            sessionIdentity: sfuLocalIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(clientProps.longTermPublicKey),
                oneTime: clientProps.oneTimePublicKey,
                mlKEM: clientProps.mlKEMPublicKey
            ),
            localKeys: sfuLocalIdentity.localKeys
            )
        }
        
        // Create an SFU->client "answer" payload and encrypt it as a RatchetMessagePacket.
        var sfuAnswerCall = decryptedOfferCall
#if canImport(WebRTC)
        let minimalAnswerSdp = "v=0\ns=-\nt=0 0\n"
        let rtcAnswer = WebRTC.RTCSessionDescription(type: .answer, sdp: minimalAnswerSdp)
        let answerSdp = try SessionDescription(fromRTC: rtcAnswer)
#else
        // Fallback: if WebRTC isn't available, skip this part (this test suite is intended for Apple builds).
        throw Issue.record("WebRTC not available; cannot construct SessionDescription for SFU->client decrypt roundtrip")
#endif
        sfuAnswerCall.metadata = try BinaryEncoder().encode(answerSdp)
        let sfuAnswerPlain = try BinaryEncoder().encode(sfuAnswerCall)
        let sfuAnswerMsg = try await sfuRatchet.ratchetEncrypt(
            plainText: sfuAnswerPlain,
            sessionId: sfuLocalIdentity.sessionIdentity.id
        )
        let sfuAnswerPacket = RatchetMessagePacket(
            sfuIdentity: sfuRecipientId,
            header: sfuAnswerMsg.header,
            ratchetMessage: sfuAnswerMsg,
            flag: .answer
        )
        
        // Decrypt on client using its SFU identity + local (pcKeyManager) bundle.
        guard let clientSfuIdentity = await session.pcKeyManager.fetchConnectionIdentityByConnectionId(sfuRecipientId) else {
            Issue.record("Client missing recipient identity for SFU")
            return
        }
        guard let clientBundle = try await session.pcKeyManager.fetchCallKeyBundle() else {
            Issue.record("Client missing local call bundle for SFU decrypt")
            return
        }
        try await step("Client decrypt SFU answer") {
            try await session.pcRatchetManager.recipientInitialization(
            sessionIdentity: clientSfuIdentity.sessionIdentity,
            sessionSymmetricKey: clientBundle.symmetricKey,
            header: sfuAnswerPacket.header,
            localKeys: clientBundle.localKeys
            )
        }
        let clientDecryptedAnswer = try await session.pcRatchetManager.ratchetDecrypt(
            sfuAnswerPacket.ratchetMessage,
            sessionId: clientSfuIdentity.sessionIdentity.id
        )
        let clientAnswerCall = try BinaryDecoder().decode(Call.self, from: clientDecryptedAnswer)
        guard let clientAnswerMetadata = clientAnswerCall.metadata else {
            Issue.record("Client decrypted answer missing metadata")
            return
        }
        let clientAnswerSdp = try BinaryDecoder().decode(SessionDescription.self, from: clientAnswerMetadata)
        #expect(clientAnswerSdp.type == .answer)
        
        // Explicitly await shutdown to ensure cleanup completes before test returns
        await session.shutdown(with: nil)
        try? await sfuRatchet.shutdown()
    }

    @Test
    func groupCall_join_allows_empty_participants() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")

        // This must not throw: group calls can join an SFU room before the roster is known.
        try await session.join(sender: local, participants: [], sfuRecipientId: sfuRecipientId, supportsVideo: true)

        let negotiated = await waitUntil {
            await transport.negotiated.isEmpty == false
        }
        #expect(negotiated, "Expected negotiateGroupIdentity to be called during join() even when participants are empty")

        await session.shutdown(with: nil)
    }
}


