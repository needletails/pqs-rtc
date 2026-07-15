import Foundation
import Testing
@testable import PQSRTC

@Suite
struct RTCSessionCryptoKeyResolutionTests {
    private let roomUUID = "8348054c-341d-46ce-bdfa-303ab5717784"
    private let groupRoomUUID = "0ee9c718-60b8-4b7b-a1a0-44798edd35c8"

    private func participant(_ secret: String, device: String = "device") throws -> Call.Participant {
        try Call.Participant(secretName: secret, nickname: "n", deviceId: device)
    }

    @Test("setMessageKey uses local sender id for true 1:1 SFU rooms")
    func setMessageKeyUsesLocalSenderIdForOneToOneSfu() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == true)
        let resolved = RTCSession.senderFrameKeyParticipantIdForSetMessageKey(
            connectionLocalParticipantId: "nudge")
        #expect(resolved == "nudge")
    }

    @Test("setMessageKey uses local sender id for multi-party group calls")
    func setMessageKeyUsesLocalSenderIdForGroupCall() throws {
        let call = try Call(
            sharedCommunicationId: groupRoomUUID,
            channelWireId: "#\(groupRoomUUID)",
            sender: try participant("a"),
            recipients: [try participant("nudge", device: "d1"), try participant("echo", device: "d2")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
        let resolved = RTCSession.senderFrameKeyParticipantIdForSetMessageKey(
            connectionLocalParticipantId: "a")
        #expect(resolved == "a")
    }

    @Test("setMessageKey uses local sender id for conf rooms even with one recipient")
    func setMessageKeyUsesLocalSenderIdForConferenceRoom() throws {
        let confId = "conf-7f79fef9-f2cb-420f-bd57-2ce87e6d24aa"
        let call = try Call(
            sharedCommunicationId: confId,
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
        let resolved = RTCSession.senderFrameKeyParticipantIdForSetMessageKey(
            connectionLocalParticipantId: "local")
        #expect(resolved == "local")
    }

    @Test("true 1:1 SFU rooms are recognized")
    func trueOneToOneSfuDetection() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == true)
    }

    @Test("multi-recipient rooms are not 1:1 SFU")
    func multiRecipientIsNotOneToOne() throws {
        let call = try Call(
            sharedCommunicationId: groupRoomUUID,
            sender: try participant("a"),
            recipients: [try participant("nudge", device: "d1"), try participant("echo", device: "d2")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
    }

    @Test("channel group rooms use application-injected sender frame keys")
    func channelGroupUsesApplicationInjectedFrameKeys() throws {
        let call = try Call(
            sharedCommunicationId: groupRoomUUID,
            channelWireId: "#israel_\(groupRoomUUID)",
            sender: try participant("nudge"),
            recipients: [
                try participant("echo", device: "d1"),
                try participant("bob", device: "d2"),
            ],
            supportsVideo: true)

        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
        #expect(RTCSession.usesApplicationInjectedGroupFrameKeys(call: call) == true)
    }

    @Test("1:1 SFU relay rooms keep pairwise call_cipher frame keys")
    func oneToOneSfuDoesNotUseApplicationInjectedGroupFrameKeys() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("nudge"),
            recipients: [try participant("echo")],
            supportsVideo: true)

        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == true)
        #expect(RTCSession.usesApplicationInjectedGroupFrameKeys(call: call) == false)
    }

    @Test("conference rooms use application-injected sender frame keys")
    func conferenceUsesApplicationInjectedFrameKeys() throws {
        let confId = "conf-7f79fef9-f2cb-420f-bd57-2ce87e6d24aa"
        let call = try Call(
            sharedCommunicationId: confId,
            sender: try participant("local"),
            recipients: [],
            supportsVideo: true)

        #expect(RTCSession.usesApplicationInjectedGroupFrameKeys(call: call) == true)
    }

    @Test("ephemeral 1:1 relay with duplicate recipient rows still counts as 1:1 SFU")
    func relayRoomWithDuplicateRecipientEntriesIsOneToOne() throws {
        let peer = try participant("echo", device: "d1")
        let dup = try Call.Participant(secretName: "echo", nickname: "n", deviceId: "d2")
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("local"),
            recipients: [peer, dup],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == true)
    }

    @Test("duplicate devices in a 1:1 relay retain pairwise frame identity resolution")
    func relayRoomWithDuplicateDevicesUsesPairwiseFrameIdentityResolution() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("local"),
            recipients: [
                try participant("echo", device: "d1"),
                try participant("echo", device: "d2"),
            ],
            supportsVideo: true)

        #expect(RTCSession.usesPairwiseFrameIdentityResolution(call: call) == true)
    }

    @Test("Android group camera reconcile avoids optional JNI receiver lookup helper")
    func androidGroupCameraReconcileAvoidsOptionalJniReceiverLookupHelper() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let androidClientSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/Android/AndroidRTCClient.swift"),
            encoding: .utf8
        )
        let peerNotificationSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift"),
            encoding: .utf8
        )

        #expect(
            !androidClientSource.contains("getRemoteVideoTrackByIdOrMid"),
            "The optional trackId/mid Android helper regressed to a crash-prone JNI bridge."
        )
        #expect(
            androidClientSource.contains("public func getRemoteVideoTrackByMid(peerConnection: RTCPeerConnection, mid: String) -> RTCVideoTrack?"),
            "Android group camera recovery should use a non-optional MID-specific helper."
        )
        #expect(
            !androidClientSource.contains("candidate.name == \"getMid\""),
            "MID fallback should use the typed Kotlin property rather than reflective method lookup."
        )
        #expect(
            peerNotificationSource.contains("rtcClient.getRemoteVideoTrackById(")
                && peerNotificationSource.contains("rtcClient.getRemoteVideoTrackByMid("),
            "Android group camera reconcile must try exact advertised track id first, then MID fallback for native id drift."
        )
    }

    @Test("1:1 SFU ignores call_cipher from sibling device that is not the active media peer")
    func oneToOneSfuRejectsSiblingDeviceCallCipher() throws {
        let activeCall = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-active")],
            supportsVideo: true)
        let activePeerCipher = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("nudge", device: "nudge-active"),
            recipients: [try participant("echo", device: "echo-active")],
            supportsVideo: true)
        let siblingCipher = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("nudge", device: "nudge-sibling"),
            recipients: [try participant("echo", device: "echo-active")],
            supportsVideo: true)

        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(connectionCall: activeCall, inboundCall: activePeerCipher))
        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(connectionCall: activeCall, inboundCall: siblingCipher) == false)
    }

    @Test("1:1 SFU ignores sibling device when stored connection call lacks channelWireId")
    func oneToOneSfuRejectsSiblingWhenConnectionCallMissingWireId() throws {
        let staleConnectionCall = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: nil,
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-active")],
            supportsVideo: true)
        let siblingCipher = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("nudge", device: "nudge-sibling"),
            recipients: [try participant("echo", device: "echo-active")],
            supportsVideo: true)

        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(
            connectionCall: staleConnectionCall,
            inboundCall: siblingCipher) == false)
    }

    @Test("likely 1:1 SFU classifies UUID rooms without channelWireId")
    func likelyOneToOneSfuWithoutWireId() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: nil,
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-active")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
        #expect(RTCSession.isLikelyOneToOneSfuRoom(call: call) == true)
    }

    @Test("1:1 SFU ignores sibling device after resolveProperRecipient call shape")
    func oneToOneSfuRejectsSiblingAfterRecipientResolution() throws {
        let resolvedConnectionCall = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-active")],
            supportsVideo: true)
        let resolvedSiblingInbound = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-sibling")],
            supportsVideo: true)

        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(
            connectionCall: resolvedConnectionCall,
            inboundCall: resolvedSiblingInbound,
            lockedRemoteDeviceId: "nudge-active",
            cipherState: .complete,
            localSecretName: "echo") == false)
        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(
            connectionCall: resolvedConnectionCall,
            inboundCall: try Call(
                sharedCommunicationId: roomUUID,
                channelWireId: "#\(roomUUID)",
                sender: try participant("echo", device: "echo-active"),
                recipients: [try participant("nudge", device: "nudge-active")],
                supportsVideo: true),
            lockedRemoteDeviceId: "nudge-active",
            cipherState: .complete,
            localSecretName: "echo"))
    }

    @Test("locked remote device id rejects sibling call_cipher after first exchange")
    func lockedRemoteDeviceRejectsSiblingCallCipher() throws {
        let connectionCall = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: nil,
            sender: try participant("echo", device: "echo-active"),
            recipients: [try participant("nudge", device: "nudge-active")],
            supportsVideo: true)
        let siblingCipher = try Call(
            sharedCommunicationId: roomUUID,
            sender: try participant("nudge", device: "nudge-sibling"),
            recipients: [try participant("echo", device: "echo-active")],
            supportsVideo: true)

        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(
            connectionCall: connectionCall,
            inboundCall: siblingCipher,
            lockedRemoteDeviceId: "nudge-active",
            cipherState: .complete) == false)
        #expect(RTCSession.shouldProcessOneToOneSfuCallCipher(
            connectionCall: connectionCall,
            inboundCall: try Call(
                sharedCommunicationId: roomUUID,
                sender: try participant("nudge", device: "nudge-active"),
                recipients: [try participant("echo", device: "echo-active")],
                supportsVideo: true),
            lockedRemoteDeviceId: "nudge-active",
            cipherState: .complete))
    }

    @Test("distinct peers do not use pairwise frame identity resolution")
    func multipartyRoomDoesNotUsePairwiseFrameIdentityResolution() throws {
        let call = try Call(
            sharedCommunicationId: groupRoomUUID,
            channelWireId: "#\(groupRoomUUID)",
            sender: try participant("local"),
            recipients: [
                try participant("echo", device: "d1"),
                try participant("bob", device: "d2"),
            ],
            supportsVideo: true)

        #expect(RTCSession.usesPairwiseFrameIdentityResolution(call: call) == false)
    }

    @Test("conf- prefixed rooms are not 1:1 SFU even with one recipient")
    func conferenceRoomIsNotOneToOne() throws {
        let confId = "conf-7f79fef9-f2cb-420f-bd57-2ce87e6d24aa"
        let call = try Call(
            sharedCommunicationId: confId,
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        #expect(RTCSession.isTrueOneToOneSfuRoom(call: call) == false)
    }

    @Test("group receiver cryptor binding is delayed for UUID placeholders")
    func delayBindingForUuidPlaceholderInGroup() {
        let shouldDelay = RTCSession.shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "0dd54da6-6ef4-4002-bd3f-5cda1d4fcfa1"
        )
        #expect(shouldDelay == true)
    }

    @Test("group receiver cryptor binding is not delayed for stable participant ids")
    func noDelayBindingForStableParticipant() {
        let shouldDelay = RTCSession.shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "echo"
        )
        #expect(shouldDelay == false)
    }

    @Test("group receiver cryptor binding skips room and placeholder participant ids")
    func groupReceiverCryptorBindingSkipsUnstableParticipantIds() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        let channelId = "broken_\(roomId)"

        #expect(RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "",
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
        // `broken_<roomId>` normalizes to publisher-style `broken` (strip connection suffix), so it
        // is no longer treated as an unstable room/placeholder id — same as `audio_echo_<roomId>`.
        #expect(!RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: channelId,
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
        #expect(RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: roomId,
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
        #expect(RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "0dd54da6-6ef4-4002-bd3f-5cda1d4fcfa1",
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
        #expect(!RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "audio_echo_\(roomId)",
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
        #expect(!RTCSession.shouldSkipReceiverFrameCryptorBindingForUnstableGroupParticipantId(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: "echo",
            connectionId: roomId,
            remoteParticipantId: channelId,
            localParticipantId: "frank"
        ))
    }

    @Test("SFU msid stream label echo_ maps to frame key id echo in 1:1 SFU")
    func sfuUnderscoreStreamLabelMapsToSecretName() {
        let resolved = RTCSession.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: "echo_",
            isOneToOneSfuRoom: true,
            isGroupCallConnection: false,
            effectiveRemoteSecretName: "echo",
            localParticipantSecretName: "nudge"
        )
        #expect(resolved == "echo")
    }

    @Test("SFU msid nudge_ maps to nudge when remote is nudge")
    func sfuUnderscoreNudgeMaps() {
        let resolved = RTCSession.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: "nudge_",
            isOneToOneSfuRoom: true,
            isGroupCallConnection: false,
            effectiveRemoteSecretName: "nudge",
            localParticipantSecretName: "echo"
        )
        #expect(resolved == "nudge")
    }

    @Test("underscore stream label is unchanged when not 1:1 SFU and not a group connection")
    func sfuUnderscoreNoMapWhenNotOneToOneRoom() {
        let resolved = RTCSession.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: "echo_",
            isOneToOneSfuRoom: false,
            isGroupCallConnection: false,
            effectiveRemoteSecretName: "echo",
            localParticipantSecretName: "nudge"
        )
        #expect(resolved == nil)
    }

    @Test("conference SFU: msid nudge_ maps to nudge when routing id is room and local is echo")
    func conferenceSfuUnderscoreStreamMapsUsingPublisherInMsid() {
        let confRoom = "conf-f12911c0-0c59-49c0-a993-a85cce05be11"
        let resolved = RTCSession.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: "nudge_",
            isOneToOneSfuRoom: false,
            isGroupCallConnection: true,
            effectiveRemoteSecretName: confRoom,
            localParticipantSecretName: "echo"
        )
        #expect(resolved == "nudge")
    }

    @Test("conference SFU media labels normalize to publisher participant ids")
    func conferenceSfuMediaLabelsNormalizeToPublisherParticipantIds() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"

        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "video_echo_\(roomId)",
            connectionId: roomId,
            localParticipantId: "frank"
        ) == "echo")

        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "audio_echo_\(roomId)",
            connectionId: "#\(roomId)",
            localParticipantId: "frank"
        ) == "echo")

        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "streamId_video_echo_\(roomId)",
            connectionId: roomId,
            localParticipantId: "frank"
        ) == "echo")
    }

    @Test("conference participant identity strips SFU media prefixes")
    func conferenceParticipantIdentityStripsSfuMediaPrefixes() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        #expect(RTCSession.conferenceParticipantIdentityKey("video_echo_\(roomId)") == "echo")
        #expect(RTCSession.conferenceParticipantIdentityKey("audio_echo_\(roomId)") == "echo")
    }

    @Test("SFU media label normalizer rejects self, UUID, and screen ids")
    func sfuMediaLabelNormalizerRejectsInvalidOwners() {
        let roomId = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "video_frank_\(roomId)",
            connectionId: roomId,
            localParticipantId: "frank"
        ) == nil)
        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "video_41769cb0-8ab0-4407-87d8-1f4c1c8e10b6_\(roomId)",
            connectionId: roomId,
            localParticipantId: "frank"
        ) == nil)
        #expect(RTCSession.normalizedRemoteParticipantIdFromSfuMediaLabel(
            "screen_echo",
            connectionId: roomId,
            localParticipantId: "frank"
        ) == nil)
    }

    @Test("stable stream id without trailing underscore returns nil from underscore normalizer")
    func sfuNoUnderscoreReturnsNil() {
        let resolved = RTCSession.normalizedReceiverFrameKeyParticipantIdForSfuUnderscoreStreamLabel(
            streamId: "echo",
            isOneToOneSfuRoom: true,
            isGroupCallConnection: false,
            effectiveRemoteSecretName: "echo",
            localParticipantSecretName: "nudge"
        )
        #expect(resolved == nil)
    }

    @Test("group UUID stream then stable stream transition keeps key provisioning coherent")
    func groupUuidToStableParticipantTransitionSimulation() throws {
        var lastFrameKeyIndexByParticipantId: [String: Int] = [:]
        let groupCall = try Call(
            sharedCommunicationId: groupRoomUUID,
            channelWireId: "#\(groupRoomUUID)",
            sender: try participant("a"),
            recipients: [try participant("nudge", device: "d1"), try participant("echo", device: "d2")],
            supportsVideo: true)

        #expect(RTCSession.isTrueOneToOneSfuRoom(call: groupCall) == false)
        let senderParticipant = RTCSession.senderFrameKeyParticipantIdForSetMessageKey(
            connectionLocalParticipantId: groupCall.sender.secretName)
        #expect(senderParticipant == "a")

        // Simulate sender-side key provisioning result from setMessageKey: local slot only.
        lastFrameKeyIndexByParticipantId[senderParticipant] = 7
        #expect(lastFrameKeyIndexByParticipantId[senderParticipant] == 7)
        #expect(lastFrameKeyIndexByParticipantId[groupRoomUUID] == nil)

        // First inbound receiver comes with UUID-like placeholder stream id.
        let uuidStreamId = "0dd54da6-6ef4-4002-bd3f-5cda1d4fcfa1"
        let shouldDelayUuid = RTCSession.shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: uuidStreamId
        )
        #expect(shouldDelayUuid == true)
        #expect(lastFrameKeyIndexByParticipantId[uuidStreamId] == nil)

        // Later renegotiation publishes stable participant id; binding should proceed.
        let stableParticipant = "echo"
        let shouldDelayStable = RTCSession.shouldDelayReceiverFrameCryptorBindingForUuidPlaceholder(
            enableEncryption: true,
            isGroupCallConnection: true,
            frameEncryptionKeyMode: .perParticipant,
            participantIdOverride: stableParticipant
        )
        #expect(shouldDelayStable == false)

        // Simulate receive-side key injection for stable participant.
        lastFrameKeyIndexByParticipantId[stableParticipant] = 7
        #expect(lastFrameKeyIndexByParticipantId[stableParticipant] == 7)
    }

    // MARK: - handleAnswer .handshakeComplete fanout regression
    //
    // Regression for commit 57b97ff: handleAnswer used to short-circuit on SFU group rooms and
    // skip the .handshakeComplete WriteTask entirely, which left the per-pair Double Ratchet
    // unfinished and surfaced as FrameCryptor `missingKey` for both 1:1-SFU and SFU group calls.
    // The fanout decision must hold for 1:1 direct, 1:1-over-SFU, and SFU group rooms, and only
    // skip when there is genuinely no addressable recipient (e.g. SFU conference rooms).

    @Test("handleAnswer fans out .handshakeComplete WriteTask for 1:1 direct rooms")
    func handshakeCompleteFanoutForOneToOneDirect() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: try participant("local", device: "local-device"))
        #expect(prepared != nil)
    }

    @Test("handleAnswer fans out .handshakeComplete WriteTask for 1:1 SFU rooms")
    func handshakeCompleteFanoutForOneToOneSfu() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            channelWireId: "#\(roomUUID)",
            sender: try participant("local"),
            recipients: [try participant("echo")],
            supportsVideo: true)
        let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: try participant("local", device: "local-device"))
        #expect(prepared != nil)
    }

    @Test("1:1 SFU media readiness only waits for receive key when FrameCryptor is enabled")
    func oneToOneSfuMediaReadinessWaitsOnlyWhenFrameCryptorEnabled() throws {
        #expect(RTCSession.shouldDeferOneToOneSfuHandshakeComplete(
            isOneToOneSfuRoom: true,
            frameEncryptionEnabled: true,
            receiveKeyReady: false) == true)
        #expect(RTCSession.shouldDeferOneToOneSfuHandshakeComplete(
            isOneToOneSfuRoom: true,
            frameEncryptionEnabled: true,
            receiveKeyReady: true) == false)
        #expect(RTCSession.shouldDeferOneToOneSfuHandshakeComplete(
            isOneToOneSfuRoom: true,
            frameEncryptionEnabled: false,
            receiveKeyReady: false) == false)
        #expect(RTCSession.shouldDeferOneToOneSfuHandshakeComplete(
            isOneToOneSfuRoom: false,
            frameEncryptionEnabled: true,
            receiveKeyReady: false) == false)
    }

    @Test("1:1 SFU remote renderer attach waits for receive key when FrameCryptor is enabled")
    func oneToOneSfuRemoteRendererAttachWaitsForReceiveKey() throws {
        #expect(RTCSession.shouldDeferOneToOneSfuRemoteRendererAttach(
            isOneToOneSfuRoom: true,
            frameEncryptionEnabled: true,
            receiveKeyReady: false) == true)
        #expect(RTCSession.shouldDeferOneToOneSfuRemoteRendererAttach(
            isOneToOneSfuRoom: true,
            frameEncryptionEnabled: true,
            receiveKeyReady: true) == false)
        #expect(RTCSession.shouldDeferOneToOneSfuRemoteRendererAttach(
            isOneToOneSfuRoom: false,
            frameEncryptionEnabled: true,
            receiveKeyReady: false) == false)
    }

#if canImport(WebRTC)
    @Test("receiver cryptor reuse requires stable track and receiver identity")
    func receiverCryptorReuseRequiresStableTrackAndReceiverIdentity() {
        #expect(RTCSession.shouldReuseReceiverFrameCryptorBinding(
            existingTrackId: "497824b0-0532-4498-89cf-8a3a89b4bff3",
            newTrackId: "497824b0-0532-4498-89cf-8a3a89b4bff3",
            existingReceiverId: "ObjectIdentifier(0x1)",
            newReceiverId: "ObjectIdentifier(0x1)"
        ))
        #expect(RTCSession.shouldReuseReceiverFrameCryptorBinding(
            existingTrackId: "497824b0-0532-4498-89cf-8a3a89b4bff3",
            newTrackId: "497824b0-0532-4498-89cf-8a3a89b4bff3",
            existingReceiverId: "ObjectIdentifier(0x1)",
            newReceiverId: "ObjectIdentifier(0x2)"
        ) == false)
        #expect(RTCSession.shouldReuseReceiverFrameCryptorBinding(
            existingTrackId: "497824b0-0532-4498-89cf-8a3a89b4bff3",
            newTrackId: "ea2d8bab-df45-4cdd-b978-71b3ae1d1107",
            existingReceiverId: "ObjectIdentifier(0x1)",
            newReceiverId: "ObjectIdentifier(0x2)"
        ) == false)
    }

    @Test("renderer recovery skips advancing ingress and attempts true decode stalls")
    func inboundRemoteVideoRendererRecoveryPolicy() {
        let advancing = RTCSession.InboundVideoFlowCheck(
            state: .advancingIngress,
            likelyCause: "test",
            audioPacketsReceived: 1,
            packetsReceived: 1,
            framesReceived: 1,
            framesDecoded: 1,
            deltaAudioPacketsReceived: 1,
            deltaPacketsReceived: 1,
            deltaFramesReceived: 1,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: advancing,
            callbackAgeMs: 4_000,
            hasAnyCallbacks: true) == false)
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: advancing,
            callbackAgeMs: 12_000,
            hasAnyCallbacks: true) == false)

        let decodeStalledWithCallbacks = RTCSession.InboundVideoFlowCheck(
            state: .decodeStalled,
            likelyCause: "inbound_video_advancing_but_decode_stalled",
            audioPacketsReceived: 10,
            packetsReceived: 90,
            framesReceived: 75,
            framesDecoded: 75,
            deltaAudioPacketsReceived: 5,
            deltaPacketsReceived: 8,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: decodeStalledWithCallbacks,
            callbackAgeMs: 2_000,
            hasAnyCallbacks: true) == false)
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: decodeStalledWithCallbacks,
            callbackAgeMs: 4_000,
            hasAnyCallbacks: true))

        let decodeStalledNoCallbacks = RTCSession.InboundVideoFlowCheck(
            state: .decodeStalled,
            likelyCause: "inbound_video_advancing_but_decode_stalled",
            audioPacketsReceived: 3,
            packetsReceived: 9,
            framesReceived: 0,
            framesDecoded: 0,
            deltaAudioPacketsReceived: 3,
            deltaPacketsReceived: 9,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: decodeStalledNoCallbacks,
            callbackAgeMs: -1,
            hasAnyCallbacks: false,
            expectationAgeMs: 12_000))

        let stalled = RTCSession.InboundVideoFlowCheck(
            state: .stalledIngress,
            likelyCause: "test",
            audioPacketsReceived: 10,
            packetsReceived: 10,
            framesReceived: 10,
            framesDecoded: 10,
            deltaAudioPacketsReceived: 0,
            deltaPacketsReceived: 0,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: stalled,
            callbackAgeMs: 3_000,
            hasAnyCallbacks: true) == false)
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: stalled,
            callbackAgeMs: 12_000,
            hasAnyCallbacks: true))
        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: nil,
            callbackAgeMs: 12_000,
            hasAnyCallbacks: true))
    }

    @Test("screen renderer recovery uses per-mid flow and recovers sooner on decode stall")
    func inboundRemoteScreenRendererRecoveryPolicy() {
        let screenDecodeStalled = RTCSession.InboundVideoFlowCheck(
            state: .decodeStalled,
            likelyCause: "inbound_screen_video_advancing_but_decode_stalled",
            audioPacketsReceived: 1,
            packetsReceived: 8,
            framesReceived: 0,
            framesDecoded: 0,
            deltaAudioPacketsReceived: 1,
            deltaPacketsReceived: 8,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        let aggregateAdvancing = RTCSession.InboundVideoFlowCheck(
            state: .advancingIngress,
            likelyCause: "inbound_video_advancing",
            audioPacketsReceived: 1,
            packetsReceived: 40,
            framesReceived: 10,
            framesDecoded: 10,
            deltaAudioPacketsReceived: 1,
            deltaPacketsReceived: 20,
            deltaFramesReceived: 5,
            deltaFramesDecoded: 5,
            dtlsState: "connected",
            selectedPairState: "succeeded")

        #expect(RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
            screenFlow: screenDecodeStalled,
            aggregateFlow: aggregateAdvancing,
            callbackAgeMs: 4_000,
            hasAnyCallbacks: false,
            expectationAgeMs: 4_000))
        #expect(RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
            screenFlow: screenDecodeStalled,
            aggregateFlow: aggregateAdvancing,
            callbackAgeMs: -1,
            hasAnyCallbacks: false,
            expectationAgeMs: 6_000))

        let transportUnstable = RTCSession.InboundVideoFlowCheck(
            state: .noTraffic,
            likelyCause: "transport_or_ice_instability",
            audioPacketsReceived: 2,
            packetsReceived: 0,
            framesReceived: 0,
            framesDecoded: 0,
            deltaAudioPacketsReceived: 2,
            deltaPacketsReceived: 0,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "closed",
            selectedPairState: "failed")
        #expect(RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
            screenFlow: transportUnstable,
            aggregateFlow: nil,
            callbackAgeMs: -1,
            hasAnyCallbacks: false,
            expectationAgeMs: 4_000))

        let screenNoTraffic = RTCSession.InboundVideoFlowCheck(
            state: .noTraffic,
            likelyCause: "audio_advancing_screen_video_flat_remote_sender_or_sfu_screen_forward_stopped",
            audioPacketsReceived: 40,
            packetsReceived: 0,
            framesReceived: 0,
            framesDecoded: 0,
            deltaAudioPacketsReceived: 5,
            deltaPacketsReceived: 0,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "connected",
            selectedPairState: "succeeded")
        #expect(RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
            screenFlow: screenNoTraffic,
            aggregateFlow: aggregateAdvancing,
            callbackAgeMs: -1,
            hasAnyCallbacks: false,
            expectationAgeMs: 6_000))
        #expect(RTCSession.shouldAttemptInboundRemoteScreenRendererRecovery(
            screenFlow: screenNoTraffic,
            aggregateFlow: aggregateAdvancing,
            callbackAgeMs: -1,
            hasAnyCallbacks: false,
            expectationAgeMs: 3_000))
    }

    @Test("transport-only camera stalls do not trigger renderer rebind recovery")
    func cameraRendererRecoverySkipsTransportOnlyNoTraffic() {
        let transportUnstable = RTCSession.InboundVideoFlowCheck(
            state: .noTraffic,
            likelyCause: "transport_or_ice_instability",
            audioPacketsReceived: 100,
            packetsReceived: 0,
            framesReceived: 0,
            framesDecoded: 0,
            deltaAudioPacketsReceived: 0,
            deltaPacketsReceived: 0,
            deltaFramesReceived: 0,
            deltaFramesDecoded: 0,
            dtlsState: "closed",
            selectedPairState: "failed")

        #expect(RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: transportUnstable,
            callbackAgeMs: 230_000,
            hasAnyCallbacks: true) == false)
    }
#endif

    @Test("handleAnswer fans out .handshakeComplete WriteTask for SFU group rooms")
    func handshakeCompleteFanoutForSfuGroup() throws {
        let call = try Call(
            sharedCommunicationId: groupRoomUUID,
            channelWireId: "#\(groupRoomUUID)",
            sender: try participant("a"),
            recipients: [
                try participant("nudge", device: "d1"),
                try participant("echo", device: "d2"),
            ],
            supportsVideo: true)
        let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: try participant("a", device: "a-device"))
        #expect(prepared != nil)
        #expect(prepared?.recipients.count == 1)
    }

    @Test("handleAnswer skips .handshakeComplete WriteTask for empty-recipient conference rooms")
    func handshakeCompleteSkipsForEmptyRecipients() throws {
        let confId = "conf-7f79fef9-f2cb-420f-bd57-2ce87e6d24aa"
        let call = try Call(
            sharedCommunicationId: confId,
            sender: try participant("local"),
            recipients: [],
            supportsVideo: true)
        let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: try participant("local", device: "local-device"))
        #expect(prepared == nil)
    }

    @Test("handleAnswer swaps sender/recipient when recipient secretName matches session participant")
    func handshakeCompleteSwapsForLocalRecipient() throws {
        let call = try Call(
            sharedCommunicationId: roomUUID,
            sender: try participant("alice"),
            recipients: [try participant("bob", device: "bob-stale-device")],
            supportsVideo: true)
        let prepared = RTCSession.prepareHandshakeCompleteCallForFanout(
            call: call,
            sessionParticipant: try participant("bob", device: "bob-real-device"))
        #expect(prepared != nil)
        // After swap, sender becomes the resolved local "bob" with the real device id and the
        // recipients list now points back to the original sender ("alice") so the WriteTask is
        // routed to the actual remote peer.
        #expect(prepared?.sender.secretName == "bob")
        #expect(prepared?.sender.deviceId == "bob-real-device")
        #expect(prepared?.recipients.count == 1)
        #expect(prepared?.recipients.first?.secretName == "alice")
    }
}
