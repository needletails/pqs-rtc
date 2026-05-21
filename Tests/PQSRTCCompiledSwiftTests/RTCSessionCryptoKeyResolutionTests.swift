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
