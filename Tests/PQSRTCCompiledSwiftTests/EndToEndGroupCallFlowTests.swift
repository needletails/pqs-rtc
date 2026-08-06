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

        let localDeviceId = try #require(UUID(uuidString: "2D4087FD-0E8A-4D96-B558-33142F345AD2"))
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: localDeviceId.uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)
        let carol = try Call.Participant(secretName: "carol", nickname: "Carol", deviceId: UUID().uuidString)

        // Join group call. This should trigger negotiateGroupIdentity on transport.
        try await step("join") {
            try await session.join(sender: local, participants: [bob, carol], sfuRecipientId: sfuRecipientId, supportsVideo: false)
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
        let serverClientIdentity = try await sfuKeyStore.createSFUSignalingRecipientIdentity(
            roomId: negotiatedCall.sharedCommunicationId,
            deviceId: localDeviceId,
            sessionContext: negotiatedCall.id.uuidString,
            props: clientProps,
            aliases: [sfuRecipientId]
        )
        let sfuExecutor = RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.ratchet"))
        let sfuRatchet = DoubleRatchetStateManager<SHA256>(executor: sfuExecutor)

        // Call used to create SFU identity and start the SFU peer connection/offer.
        var call = negotiatedCall
        call.signalingIdentityProps = sfuProps

        try await step("createSFUIdentity + beginGroupCallMedia (encrypt offer)") {
            try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
            try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(
                sfuRecipientId: sfuRecipientId,
                updatedCall: call)
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
            sessionIdentity: serverClientIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            header: offerPacket.header,
            localKeys: sfuLocalIdentity.localKeys
            )
        }
        let decryptedOfferBytes = try await sfuRatchet.ratchetDecrypt(
            offerPacket.ratchetMessage,
            sessionId: serverClientIdentity.sessionIdentity.id
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
            sessionId: serverClientIdentity.sessionIdentity.id
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
            sessionIdentity: serverClientIdentity.sessionIdentity,
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
            sessionId: serverClientIdentity.sessionIdentity.id
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
        let clientBundle = try await session.pcKeyManager.fetchCallKeyBundle()
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

    @Test
    func groupCallNegotiation_preservesCallIdentity_whenRoutingViaChannel() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sharedCommunicationId = UUID().uuidString
        let channelWireId = "#travel_\(UUID().uuidString.lowercased())"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "")
        let carol = try Call.Participant(secretName: "carol", nickname: "Carol", deviceId: "")
        let call = try Call(
            sharedCommunicationId: sharedCommunicationId,
            channelWireId: channelWireId,
            sender: local,
            recipients: [bob, carol],
            supportsVideo: true
        )

        try await session.groupCallNegotiation(call: call, sfuRecipientId: channelWireId)

        let negotiated = await waitUntil {
            await transport.negotiated.isEmpty == false
        }
        #expect(negotiated, "Expected negotiateGroupIdentity to be called during channel-backed join")

        let negotiatedEntry = await transport.negotiated.last
        #expect(negotiatedEntry?.sfuRecipientId == channelWireId)
        #expect(negotiatedEntry?.call.sharedCommunicationId == sharedCommunicationId)
        #expect(negotiatedEntry?.call.channelWireId == channelWireId)
        #expect(negotiatedEntry?.call.signalingIdentityProps != nil)

        await session.shutdown(with: nil)
    }

    @Test
    func channelBackedGroupCall_routesPacketsViaChannelWireId() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sharedCommunicationId = UUID().uuidString
        let channelWireId = "#travel_\(UUID().uuidString.lowercased())"
        let localDeviceId = try #require(UUID(uuidString: "2D4087FD-0E8A-4D96-B558-33142F345AD2"))
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: localDeviceId.uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        let call = try Call(
            sharedCommunicationId: sharedCommunicationId,
            channelWireId: channelWireId,
            sender: local,
            recipients: [bob],
            supportsVideo: false
        )

        try await session.groupCallNegotiation(call: call, sfuRecipientId: channelWireId)

        let negotiated = await waitUntil {
            await transport.negotiated.isEmpty == false
        }
        #expect(negotiated, "Expected negotiateGroupIdentity to be called during channel-backed join")

        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sharedCommunicationId,
            secretName: "sfu-\(sharedCommunicationId)"
        )
        guard let sfuProps = await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey) else {
            Issue.record("Missing SFU identity props")
            return
        }

        let sfuExecutor = RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.channel-route"))
        let sfuRatchet = DoubleRatchetStateManager<SHA256>(executor: sfuExecutor)

        let negotiatedCall = await transport.negotiated.last!.call
        guard let clientProps = negotiatedCall.signalingIdentityProps else {
            Issue.record("Expected channel-backed registration to include client signaling props")
            return
        }
        let serverClientIdentity = try await sfuKeyStore.createSFUSignalingRecipientIdentity(
            roomId: sharedCommunicationId,
            deviceId: localDeviceId,
            sessionContext: negotiatedCall.id.uuidString,
            props: clientProps,
            aliases: [channelWireId]
        )

        var registrationReply = negotiatedCall
        registrationReply.signalingIdentityProps = sfuProps

        try await session.createSFUIdentity(sfuRecipientId: channelWireId, call: registrationReply)
        try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(
            sfuRecipientId: channelWireId,
            updatedCall: registrationReply)

        let gotOffer = await waitUntil { await transport.sfuMessages.contains(where: { $0.packet.flag == .offer }) }
        #expect(gotOffer, "Expected encrypted SFU offer packet to be sent")

        let offerPacket = await transport.sfuMessages.last(where: { $0.packet.flag == .offer })!.packet
        #expect(offerPacket.sfuIdentity == channelWireId)

        try await sfuRatchet.recipientInitialization(
            sessionIdentity: serverClientIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            header: offerPacket.header,
            localKeys: sfuLocalIdentity.localKeys
        )

        let decryptedOfferBytes = try await sfuRatchet.ratchetDecrypt(
            offerPacket.ratchetMessage,
            sessionId: serverClientIdentity.sessionIdentity.id
        )
        let decryptedOfferCall = try BinaryDecoder().decode(Call.self, from: decryptedOfferBytes)
        #expect(decryptedOfferCall.sharedCommunicationId == sharedCommunicationId)
        #expect(decryptedOfferCall.channelWireId == channelWireId)

        await session.shutdown(with: nil)
        try? await sfuRatchet.shutdown()
    }

    /// Transport whose SFU sends never complete (until cancelled), simulating a congested
    /// uplink / stalled websocket write. Records attempts so ordering can be asserted.
    actor BlockingSfuTransport: RTCTransportEvents {
        private(set) var negotiated: [(call: Call, sfuRecipientId: String)] = []
        private(set) var sendAttempts = 0
        private var blockedContinuations: [CheckedContinuation<Void, Error>] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
            sendAttempts += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    blockedContinuations.append(continuation)
                }
            } onCancel: {
                Task { await self.releaseAllBlockedSends() }
            }
        }
        private func releaseAllBlockedSends() {
            for continuation in blockedContinuations {
                continuation.resume(throwing: CancellationError())
            }
            blockedContinuations.removeAll()
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

    /// Regression: a transport send blocked on a congested uplink must not stall the crypto
    /// pipeline. Before the outbound send lane existed, the send was awaited inline inside the
    /// serial TaskProcessor loop, so one wedged websocket write queued every later job — in
    /// production the inbound SFU answer decrypted 60+ seconds late, the remote SDP was applied
    /// after the ICE fallback fired, and the group call tore down a healthy setup.
    @Test
    func cryptoPipeline_isNotBlocked_byWedgedTransportSend() async throws {
        let transport = BlockingSfuTransport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let localDeviceId = try #require(UUID(uuidString: "2D4087FD-0E8A-4D96-B558-33142F345AD2"))
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: localDeviceId.uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil { await transport.negotiated.isEmpty == false }
        #expect(negotiated, "Expected negotiateGroupIdentity during join()")
        let negotiatedCall = await transport.negotiated.last!.call
        let clientProps = try #require(negotiatedCall.signalingIdentityProps)

        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sfuRecipientId,
            secretName: sfuRecipientId
        )
        let sfuProps = try #require(await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey))
        let serverClientIdentity = try await sfuKeyStore.createSFUSignalingRecipientIdentity(
            roomId: negotiatedCall.sharedCommunicationId,
            deviceId: localDeviceId,
            sessionContext: negotiatedCall.id.uuidString,
            props: clientProps,
            aliases: [sfuRecipientId]
        )
        let sfuExecutor = RatchetExecutor(queue: DispatchQueue(label: "tests.sfu.blocked-send"))
        let sfuRatchet = DoubleRatchetStateManager<SHA256>(executor: sfuExecutor)

        var call = negotiatedCall
        call.signalingIdentityProps = sfuProps

        // Offer is encrypted and handed to the send lane; the transport wedges the send forever.
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
        try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(
            sfuRecipientId: sfuRecipientId,
            updatedCall: call)
        let offerSendAttempted = await waitUntil(timeoutSeconds: 5.0) { await transport.sendAttempts == 1 }
        #expect(offerSendAttempted, "Expected the encrypted offer send to be attempted (and wedge)")

        // With the offer send wedged, later outbound work must still encrypt (job cache drains;
        // the packet queues in the lane behind the blocked send).
        try await session.startSendingCandidates(call: call)
        await session.peerConnectionNotificationsContinuation.yield(
            .generatedIceCandidate(sfuRecipientId, "candidate: 1 1 UDP 1234 1.2.3.4 9999 typ host", 0, "0")
        )
        let writesDrained = await waitUntil(timeoutSeconds: 5.0) {
            await session.taskProcessor.jobs.isEmpty
        }
        #expect(writesDrained, "Encrypt pipeline stalled behind a wedged transport send (write path)")
        #expect(await transport.sendAttempts == 1, "Send lane must stay serial: candidate queues behind the wedged offer send")

        // Inbound decrypts must also flow while the send is wedged: SFU encrypts an answer to the
        // client; the stream job must decrypt and complete (the handler may reject the minimal
        // SDP — irrelevant here; the job leaving the cache proves the pipeline was not blocked).
        try await sfuRatchet.senderInitialization(
            sessionIdentity: serverClientIdentity.sessionIdentity,
            sessionSymmetricKey: sfuLocalIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(clientProps.longTermPublicKey),
                oneTime: clientProps.oneTimePublicKey,
                mlKEM: clientProps.mlKEMPublicKey
            ),
            localKeys: sfuLocalIdentity.localKeys
        )
#if canImport(WebRTC)
        let rtcAnswer = WebRTC.RTCSessionDescription(type: .answer, sdp: "v=0\ns=-\nt=0 0\n")
        let answerSdp = try SessionDescription(fromRTC: rtcAnswer)
#else
        throw Issue.record("WebRTC not available; cannot construct SessionDescription")
#endif
        var sfuAnswerCall = call
        sfuAnswerCall.metadata = try BinaryEncoder().encode(answerSdp)
        let sfuAnswerMsg = try await sfuRatchet.ratchetEncrypt(
            plainText: try BinaryEncoder().encode(sfuAnswerCall),
            sessionId: serverClientIdentity.sessionIdentity.id
        )
        let answerPacket = RatchetMessagePacket(
            sfuIdentity: sfuRecipientId,
            header: sfuAnswerMsg.header,
            ratchetMessage: sfuAnswerMsg,
            flag: .answer
        )
        try await session.taskProcessor.feedTask(
            task: EncryptableTask(
                task: .streamMessage(
                    StreamTask(
                        senderSecretName: sfuRecipientId,
                        senderDeviceId: nil,
                        packet: answerPacket,
                        call: call)),
                priority: .urgent))
        let inboundDrained = await waitUntil(timeoutSeconds: 5.0) {
            await session.taskProcessor.jobs.isEmpty
        }
        #expect(inboundDrained, "Inbound decrypt stalled behind a wedged transport send (the production 60s answer delay)")

        // Teardown cancels the wedged send via the outbound lane shutdown.
        await session.shutdown(with: nil)
        try? await sfuRatchet.shutdown()
    }
}
