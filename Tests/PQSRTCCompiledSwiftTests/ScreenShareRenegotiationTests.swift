import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// Regression tests for conference screen-share stop → restart over SFU renegotiation.
///
/// WebRTC often reuses the same recv transceiver and does not emit a second `didAddReceiver`.
/// `reconcile*RemoteScreenTracksAfterSetRemoteSDP` must surface resumed shares from SDP alone.
@Suite(.serialized)
struct ScreenShareRenegotiationTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
        case negotiationFailed(String)
    }

    private let conferenceConnectionId = "#conf-screenshare-renegotiation"

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func makeConferenceCall() throws -> Call {
        let sender = try Call.Participant(secretName: "nudge", nickname: "nudge", deviceId: "nudge-device")
        var call = try Call(
            sharedCommunicationId: conferenceConnectionId,
            channelWireId: conferenceConnectionId,
            sender: sender,
            recipients: []
        )
        call.supportsVideo = true
        return call
    }

    private func makeConferenceConnection(peerConnection: RTCPeerConnection) async throws -> RTCConnection {
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: conferenceConnectionId,
            secretName: "nudge"
        )
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: conferenceConnectionId,
            logger: NeedleTailLogger("[ScreenShareRenegotiationTests]"),
            continuation: continuation
        )
        return RTCConnection(
            id: conferenceConnectionId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "nudge",
            recipient: "sfu",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: try makeConferenceCall()
        )
    }

    private func makeScreenVideoTrack(trackId: String = "screen_echo_conf") -> RTCVideoTrack {
        let source = RTCSession.factory.videoSource()
        return RTCSession.factory.videoTrack(with: source, trackId: trackId)
    }

    private func makeCameraVideoTrack(trackId: String = "camera_echo_conf") -> RTCVideoTrack {
        let source = RTCSession.factory.videoSource()
        return RTCSession.factory.videoTrack(with: source, trackId: trackId)
    }

    private func cameraOnlyConferenceSDP() -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=msid:echo echo_camera
        a=sendonly
        """
    }

    private func screenShareConferenceSDP(participant: String = "echo") -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=msid:echo echo_camera
        a=sendonly
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=msid:screen_\(participant) screen_\(participant)_track
        a=sendonly
        """
    }

    private func inactiveScreenShareConferenceSDP(participant: String = "echo") -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=msid:echo echo_camera
        a=sendonly
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=inactive
        a=msid:screen_\(participant) screen_\(participant)_track
        """
    }

    private func sfuRelayRestartScreenShareSDP(
        participant: String = "nudge",
        cameraTrackId: String = "0cdba791-3bcb-4612-b1fc-ac3ab7a69176",
        screenTrackId: String = "8726d5a1-397a-4847-8d3a-48644fcf0afc"
    ) -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=msid:\(participant) \(cameraTrackId)
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 98
        c=IN IP4 0.0.0.0
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 99
        c=IN IP4 0.0.0.0
        a=msid:\(participant) \(screenTrackId)
        a=sendrecv
        """
    }

    private func makeViewerConferenceConnection(peerConnection: RTCPeerConnection) async throws -> RTCConnection {
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: conferenceConnectionId,
            secretName: "echo"
        )
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: conferenceConnectionId,
            logger: NeedleTailLogger("[ScreenShareRenegotiationTests]"),
            continuation: continuation
        )
        let sender = try Call.Participant(secretName: "echo", nickname: "echo", deviceId: "echo-device")
        var call = try Call(
            sharedCommunicationId: conferenceConnectionId,
            channelWireId: conferenceConnectionId,
            sender: sender,
            recipients: []
        )
        call.supportsVideo = true
        return RTCConnection(
            id: conferenceConnectionId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "echo",
            recipient: "sfu",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    private func streamIdPrefixedScreenShareSDP(participant: String = "echo") -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=msid:streamId_screen_\(participant) screen_\(participant)_track
        a=sendonly
        """
    }

    private func configureGroupSession(_ session: RTCSession) async {
        session.isGroupCall = true
        session.activeConnectionId = conferenceConnectionId
    }

    private actor RemoteScreenEventCollector {
        var events: [RemoteScreenTrackEvent] = []
        func append(_ event: RemoteScreenTrackEvent) { events.append(event) }
        func snapshot() -> [RemoteScreenTrackEvent] { events }
    }

    private func captureRemoteScreenEvents(
        from session: RTCSession,
        during operation: () async throws -> Void
    ) async throws -> [RemoteScreenTrackEvent] {
        let collector = RemoteScreenEventCollector()
        let stream = await session.remoteScreenTrackStream()
        let listenTask = Task {
            for await event in stream {
                await collector.append(event)
            }
        }
        try await operation()
        try? await Task.sleep(nanoseconds: 150_000_000)
        listenTask.cancel()
        return await collector.snapshot()
    }

    private func negotiateScreenShareOntoReceiver(
        receiver: RTCPeerConnection,
        participant: String = "echo"
    ) async throws -> String {
        let sender = try makePeerConnection()
        let screenTrack = makeScreenVideoTrack(trackId: "screen_\(participant)_\(conferenceConnectionId)")
        guard sender.add(screenTrack, streamIds: ["screen_\(participant)"]) != nil else {
            throw TestError.negotiationFailed("Failed to add screen sender track")
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )

        let offer = try await sender.offer(for: constraints)
        try await sender.setLocalDescription(offer)
        try await receiver.setRemoteDescription(offer)

        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let answer = try await receiver.answer(for: answerConstraints)
        try await receiver.setLocalDescription(answer)
        try await sender.setRemoteDescription(answer)

        return offer.sdp
    }

    @Test("SDP reconcile removes stored screen share when SFU stops advertising it")
    func reconcileRemovesScreenShareWhenSDPStopsAdvertising() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                cameraOnlyConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] == nil)
        #expect(events.contains {
            $0.participantId == "echo" && $0.isActive == false
        })
    }

    @Test("SDP reconcile re-emits active when screen share resumes with an already mapped track")
    func reconcileReEmitsActiveWhenMappedTrackStillExists() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }
        #expect(events.contains {
            $0.participantId == "echo" && $0.isActive == true
        })

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] != nil)
    }

    @Test("SDP reconcile maps a live screen receiver when share restarts without didAddReceiver")
    func reconcileDiscoversScreenShareFromReceiverAfterRenegotiation() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        let negotiatedOfferSDP = try await negotiateScreenShareOntoReceiver(receiver: receiverPC)

        let connection = try await makeConferenceConnection(peerConnection: receiverPC)
        await session.connectionManager.addConnection(connection)
        #expect(connection.remoteScreenTracksByParticipantId.isEmpty)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                negotiatedOfferSDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] != nil)
        #expect(events.contains {
            $0.participantId == "echo" && $0.isActive == true
        })
    }

    @Test("stop then restart reconcile cycle emits inactive then active for the same participant")
    func reconcileStopThenRestartCycle() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let stopEvents = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                cameraOnlyConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }
        #expect(stopEvents.contains { $0.participantId == "echo" && $0.isActive == false })

        let afterStop = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(afterStop?.remoteScreenTracksByParticipantId["echo"] == nil)

        if var restored = await session.connectionManager.findConnection(with: conferenceConnectionId) {
            restored.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
            await session.connectionManager.updateConnection(id: conferenceConnectionId, with: restored)
        }

        let restartEvents = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }
        #expect(restartEvents.contains { $0.participantId == "echo" && $0.isActive == true })
    }

    @Test("inactive screen-share media sections are treated as stopped")
    func reconcileRemovesShareWhenScreenSectionIsInactive() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                inactiveScreenShareConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] == nil)
        #expect(events.contains { $0.participantId == "echo" && $0.isActive == false })
    }

    @Test("inactive screen-share media sections remove a lingering receiver")
    func reconcileRemovesInactiveShareEvenWhenReceiverIsStillLive() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC)

        var connection = try await makeConferenceConnection(peerConnection: receiverPC)
        if let screenTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { RTCSession.isScreenShareId($0.trackId) }
        ) {
            connection.remoteScreenTracksByParticipantId["echo"] = screenTrack
        } else {
            Issue.record("Missing live screen receiver")
            return
        }
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                inactiveScreenShareConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] == nil)
        #expect(events.contains { $0.participantId == "echo" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "echo" && $0.isActive == true })
    }

    @Test("SDP reconcile preserves relay-style restarted screen share without screen_ msid")
    func reconcilePreservesRelayStyleRestartedShare() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeViewerConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["nudge"] = makeScreenVideoTrack(
            trackId: "8726d5a1-397a-4847-8d3a-48644fcf0afc"
        )
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuRelayRestartScreenShareSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] != nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == true })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == false })
    }

    @Test("streamId-prefixed screen msid resumes sharing for the same participant")
    func reconcileAcceptsStreamIdPrefixedScreenMsid() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                streamIdPrefixedScreenShareSDP(),
                connectionId: conferenceConnectionId
            )
        }

        #expect(events.contains { $0.participantId == "echo" && $0.isActive == true })
    }

    @Test("remote screen track stream reproduces active shares for late subscribers")
    func remoteScreenTrackStreamReplaysActiveShares() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        let stream = await session.remoteScreenTrackStream()
        var replayed: [RemoteScreenTrackEvent] = []
        let listenTask = Task {
            for await event in stream {
                replayed.append(event)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        listenTask.cancel()

        #expect(replayed.contains { $0.participantId == "echo" && $0.isActive == true })
    }

    @Test("remote screen track stream does not replay stopped shares")
    func remoteScreenTrackStreamDoesNotReplayStoppedShares() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
            inactiveScreenShareConferenceSDP(),
            connectionId: conferenceConnectionId
        )

        let stream = await session.remoteScreenTrackStream()
        var replayed: [RemoteScreenTrackEvent] = []
        let listenTask = Task {
            for await event in stream {
                replayed.append(event)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        listenTask.cancel()

        #expect(!replayed.contains { $0.participantId == "echo" && $0.isActive == true })
    }

    private func sfuRecvonlyPlaceholderConferenceSDP() -> String {
        """
        v=0
        o=- 5040176827671334280 5 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=recvonly
        """
    }

    private func sfuStoppedScreenShareWithActiveCameraSDP(
        participant: String = "nudge",
        cameraTrackId: String = "fe1af846-4cbc-4c0b-b278-4f16f91b6983"
    ) -> String {
        """
        v=0
        o=- 5040176827671334280 6 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(participant) audio_\(participant)_track
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(participant) \(cameraTrackId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=recvonly
        """
    }

    @Test("SDP reconcile keeps explicit screen receiver when camera mapping was cleared and SDP has no msid")
    func reconcileKeepsExplicitScreenReceiverWhenCameraMappingCleared() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        let screenTrackId = "screen_nudge_\(conferenceConnectionId)"
        if let screenTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { RTCSession.isScreenShareId($0.trackId) }
        ) {
            connection.remoteScreenTracksByParticipantId["nudge"] = screenTrack
        } else {
            connection.remoteScreenTracksByParticipantId["nudge"] = makeScreenVideoTrack(trackId: screenTrackId)
        }
        connection.remoteVideoTracksByParticipantId.removeAll()
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuRecvonlyPlaceholderConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] != nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == true })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == false })
    }

    @Test("SDP reconcile removes stale screen receiver when SFU leaves recvonly placeholder after stop")
    func reconcileRemovesScreenReceiverWhenStopLeavesRecvonlyPlaceholder() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        guard let screenTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { RTCSession.isScreenShareId($0.trackId) }
        ) else {
            Issue.record("Missing live screen receiver")
            return
        }
        connection.remoteScreenTracksByParticipantId["nudge"] = screenTrack
        connection.remoteVideoTracksByParticipantId["nudge"] = makeCameraVideoTrack(
            trackId: "fe1af846-4cbc-4c0b-b278-4f16f91b6983"
        )
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuStoppedScreenShareWithActiveCameraSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile ignores non-group connections")
    func reconcileIgnoresOneToOneConnections() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }

        let oneToOneId = UUID().uuidString
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(connectionId: oneToOneId, secretName: "nudge")
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: oneToOneId,
            logger: NeedleTailLogger("[ScreenShareRenegotiationTests]"),
            continuation: continuation
        )
        let sender = try Call.Participant(secretName: "nudge", nickname: "nudge", deviceId: "nudge-device")
        let recipient = try Call.Participant(secretName: "echo", nickname: "echo", deviceId: "echo-device")
        let call = try Call(sharedCommunicationId: oneToOneId, sender: sender, recipients: [recipient])

        var connection = RTCConnection(
            id: oneToOneId,
            peerConnection: try makePeerConnection(),
            delegateWrapper: delegateWrapper,
            sender: "nudge",
            recipient: "echo",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
        connection.remoteScreenTracksByParticipantId["echo"] = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        _ = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                cameraOnlyConferenceSDP(),
                connectionId: oneToOneId
            )
        }

        let updated = await session.connectionManager.findConnection(with: oneToOneId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] != nil)
    }
}
#endif

@Suite
struct ScreenShareOfferTimingTests {
    @Test("ReplayKit app-screen capture defers SFU renegotiation until broadcast starts")
    func replayKitDefersOfferUntilCaptureReady() {
        #expect(RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .appScreen))
        #expect(!RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .androidScreen))
        #expect(!RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .entireScreen(displayID: 1)))
        #expect(!RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .window(windowID: 1, title: "Notes")))
    }
}

@Suite
struct ScreenShareSdpParserTests {
    private func identityResolve(_ label: String) -> String? {
        if let participant = RTCSession.participantIdFromScreenShareId(label) {
            return participant
        }
        return label.hasPrefix(RTCSession.screenTrackPrefix) ? label : nil
    }

    private func direction(forMid targetMid: String, in sdp: String) -> String? {
        var currentMid: String?
        for rawLine in sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                currentMid = nil
            } else if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
            } else if currentMid == targetMid,
                      ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                return String(line.dropFirst("a=".count))
            }
        }
        return nil
    }

    @Test("shared SDP parser detects active screen-share sections")
    func parserDetectsActiveScreenShare() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=msid:screen_echo screen_echo_track
        a=sendonly
        """
        let shares = RTCSession.advertisedRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge",
            resolveParticipantId: identityResolve
        )
        #expect(shares == [RTCSession.AdvertisedRemoteScreenShare(participantId: "echo", trackId: "screen_echo_track")])
    }

    @Test("shared SDP parser ignores inactive screen-share sections")
    func parserIgnoresInactiveScreenShare() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=inactive
        a=msid:screen_echo screen_echo_track
        """
        let shares = RTCSession.advertisedRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge",
            resolveParticipantId: identityResolve
        )
        #expect(shares.isEmpty)
    }

    @Test("active screen-share mid parser excludes inactive stop offers")
    func parserActiveScreenShareMidsExcludeInactiveStopOffers() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=msid:streamId_nudge video_nudge_track
        m=video 9 UDP/TLS/RTP/SAVPF 97
        a=mid:2
        a=sendonly
        a=msid:screen_nudge screen_nudge_track
        m=video 9 UDP/TLS/RTP/SAVPF 98
        a=mid:3
        a=inactive
        a=msid:screen_echo screen_echo_track
        """

        #expect(RTCSession.activeScreenShareVideoMids(in: sdp) == ["2"])
    }

    @Test("answer SDP helper forces restarted remote screen mids to recvonly")
    func answerSdpForcesRestartedRemoteScreenMidRecvonly() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        let generatedInactiveAnswer = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendonly
        a=msid:streamId_echo video_echo_track
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=inactive
        """

        let modified = await session.modifySDP(
            sdp: generatedInactiveAnswer,
            hasVideo: true,
            preserveVideoDirectionsForMids: ["2"],
            forceReceiveOnlyVideoMids: ["2"]
        )

        #expect(direction(forMid: "2", in: modified) == "recvonly")
    }

    @Test("shared SDP parser accepts streamId-prefixed screen msid")
    func parserAcceptsStreamIdPrefixedMsid() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=msid:streamId_screen_echo screen_echo_track
        a=sendonly
        """
        let shares = RTCSession.advertisedRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge",
            resolveParticipantId: identityResolve
        )
        #expect(shares == [RTCSession.AdvertisedRemoteScreenShare(participantId: "echo", trackId: "screen_echo_track")])
    }

    @Test("relay-style SDP parser detects second active video section for same participant")
    func parserDetectsRelayStyleSecondVideoSection() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=msid:nudge 0cdba791-3bcb-4612-b1fc-ac3ab7a69176
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 97
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 99
        a=msid:nudge 8726d5a1-397a-4847-8d3a-48644fcf0afc
        a=sendrecv
        """
        let shares = RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: sdp,
            localParticipantId: "echo"
        ) { label in
            label == "nudge" ? "nudge" : nil
        }
        #expect(shares == [
            RTCSession.AdvertisedRemoteScreenShare(
                participantId: "nudge",
                trackId: "8726d5a1-397a-4847-8d3a-48644fcf0afc"
            )
        ])
    }

    @Test("shared SDP parser skips local participant screen msid")
    func parserSkipsLocalParticipant() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 97
        c=IN IP4 0.0.0.0
        a=msid:screen_nudge screen_nudge_track
        a=sendonly
        """
        let shares = RTCSession.advertisedRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge",
            resolveParticipantId: identityResolve
        )
        #expect(shares.isEmpty)
    }
}
