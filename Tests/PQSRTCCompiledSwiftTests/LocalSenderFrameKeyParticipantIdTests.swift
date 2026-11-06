import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// The local sender key and the sender FrameCryptors must use the same key-provider slot.
///
/// WebRTC's key provider matches participant ids exactly. `setFrameEncryptionKey` stores the key
/// under the canonical identity key, so a sender cryptor bound to the raw mixed-case
/// `secretName` reads an empty slot (missingKey) and every outbound frame is discarded.
@Suite(.serialized)
struct LocalSenderFrameKeyParticipantIdTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private let connectionId = "conf-7f79fef9-f2cb-420f-bd57-2ce87e6d24aa"
    private let localSecretName = "Alice"

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func makeConnection(peerConnection: RTCPeerConnection) async throws -> RTCConnection {
        let sender = try Call.Participant(secretName: localSecretName, nickname: localSecretName, deviceId: "alice-device")
        var call = try Call(sharedCommunicationId: connectionId, sender: sender, recipients: [])
        call.supportsVideo = true
        let localIdentity = try await KeyManager().generateSenderIdentity(
            connectionId: connectionId,
            secretName: localSecretName)
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        return RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: connectionId,
                logger: NeedleTailLogger("[LocalSenderFrameKeyParticipantIdTests]"),
                continuation: continuation),
            sender: localSecretName,
            recipient: connectionId,
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call)
    }

    @Test("Sender FrameCryptors read the slot setFrameEncryptionKey installed for a mixed-case local id")
    func senderCryptorsReadInstalledSlotForMixedCaseLocalId() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        let peerConnection = try makePeerConnection()
        let factory = RTCSession.factory
        let videoSender = try #require(peerConnection.add(
            factory.videoTrack(with: factory.videoSource(), trackId: "video_\(localSecretName)"),
            streamIds: ["stream"]))
        let audioSender = try #require(peerConnection.add(
            factory.audioTrack(withTrackId: "audio_\(localSecretName)"),
            streamIds: ["stream"]))
        let screenSender = try #require(peerConnection.add(
            factory.videoTrack(with: factory.videoSource(), trackId: "screen_\(localSecretName)"),
            streamIds: ["screen"]))
        let connection = try await makeConnection(peerConnection: peerConnection)
        await session.connectionManager.addConnection(connection)

        let key = Data((0..<32).map { UInt8($0) })
        await session.setFrameEncryptionKey(key, index: 0, for: localSecretName)
        for kind: RTCSession.TrackKind in [.videoSender(videoSender), .audioSender(audioSender), .screenSender(screenSender)] {
            let latest = try #require(await session.connectionManager.findConnection(with: connectionId))
            try await session.createEncryptedFrame(connection: latest, kind: kind)
        }

        let updated = try #require(await session.connectionManager.findConnection(with: connectionId))
        for cryptor in [updated.videoSenderCryptor, updated.audioSenderCryptor, updated.screenSenderCryptor] {
            let cryptor = try #require(cryptor)
            #expect(await session.exportFrameEncryptionKey(index: 0, for: cryptor.participantId) == key,
                    "sender cryptor participantId='\(cryptor.participantId)' has no installed key")
        }

        // The 1:1 setMessageKey sender slot follows the same rule as the cryptor binding.
        #expect(RTCSession.senderFrameKeyParticipantIdForSetMessageKey(
            connectionLocalParticipantId: localSecretName) == updated.videoSenderCryptor?.participantId)

        await session.connectionManager.removeConnection(with: connectionId)
        peerConnection.close()
    }
}
#endif

@Suite
struct AndroidLocalSenderFrameKeyParticipantIdSourceTests {
    @Test("Android sender FrameCryptors bind the canonical local sender slot")
    func androidSenderCryptorsBindCanonicalLocalSenderSlot() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cipher = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+RTCCipherTransport.swift"),
            encoding: .utf8)
        let body = try SourceContract.sourceBody(
            of: "createEncryptedFrame(connection: RTCConnection) async throws",
            in: cipher)
        #expect(body.contains("senderFrameKeyParticipantIdForSetMessageKey("))
        #expect(!body.contains("participant: connection.localParticipantId"))

        // The screen sender reads the same slot: start-share and the addedStream re-attach.
        for path in ["Sources/PQSRTC/RTCSession+ScreenShare.swift",
                     "Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift"] {
            let source = try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
            let calls = source.components(separatedBy: "rtcClient.createScreenSenderEncryptedFrame(").dropFirst()
            #expect(!calls.isEmpty, "\(path) has no screen sender attach")
            for call in calls {
                #expect(call.prefix(160).contains("senderFrameKeyParticipantIdForSetMessageKey("),
                        "\(path) binds the screen sender to a raw local id")
            }
        }
    }
}
