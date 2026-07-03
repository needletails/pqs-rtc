import BinaryCodable
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

    private var conferenceConnectionId: String { "#conf-screenshare-renegotiation" }

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

    private func makeConferenceConnection(
        peerConnection: RTCPeerConnection,
        connectionId: String? = nil,
        call overrideCall: Call? = nil
    ) async throws -> RTCConnection {
        let connectionId = connectionId ?? conferenceConnectionId
        let call: Call
        if let overrideCall {
            call = overrideCall
        } else {
            call = try makeConferenceCall()
        }
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: connectionId,
            secretName: "nudge"
        )
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: connectionId,
            logger: NeedleTailLogger("[ScreenShareRenegotiationTests]"),
            continuation: continuation
        )
        return RTCConnection(
            id: connectionId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "nudge",
            recipient: "sfu",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    private func makeScreenVideoTrack(trackId: String = "screen_echo_conf") -> RTCVideoTrack {
        let source = RTCSession.factory.videoSource()
        return RTCSession.factory.videoTrack(with: source, trackId: trackId)
    }

    @Test("Deferred screen share start is inactive for presentation until capture is ready")
    func deferredScreenShareStartIsInactiveForPresentationUntilCaptureReady() async throws {
        let connectionId = conferenceConnectionId
        let pending: Set<String> = [connectionId.normalizedConnectionId]
        var connection = try await makeConferenceConnection(
            peerConnection: try makePeerConnection(),
            connectionId: connectionId
        )
        connection.localScreenTrack = makeScreenVideoTrack()

        #expect(!RTCSession.isLocalScreenShareActiveForPresentation(
            connections: [connection],
            pendingCaptureReadyIds: pending
        ))
        #expect(RTCSession.isLocalScreenShareActiveForPresentation(
            connections: [connection],
            pendingCaptureReadyIds: []
        ))
    }

    private func identityResolve(_ label: String) -> String? {
        if let participant = RTCSession.participantIdFromScreenShareId(label) {
            return participant
        }
        return label.hasPrefix(RTCSession.screenTrackPrefix) ? label : nil
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
        await session.testing_configureGroupSessionForTests(activeConnectionId: conferenceConnectionId)
    }

    private actor RemoteScreenEventCollector {
        var events: [RemoteScreenTrackEvent] = []
        func append(_ event: RemoteScreenTrackEvent) { events.append(event) }
        func removeAll() { events.removeAll() }
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
        try? await Task.sleep(nanoseconds: 50_000_000)
        await collector.removeAll()
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

    @Test("SDP reconcile does not re-emit active for an unchanged mapped screen track")
    func reconcileDoesNotReEmitActiveForUnchangedMappedTrack() async throws {
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
        #expect(events.isEmpty)

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] != nil)
        #expect(updated?.suppressedRemoteScreenShareParticipantIds.contains("echo") == false)
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

        let receiverPC = try makePeerConnection()
        let restartSDP = try await negotiateScreenShareOntoReceiver(receiver: receiverPC)
        await session.connectionManager.removeConnection(with: conferenceConnectionId)
        let restartConnection = try await makeConferenceConnection(peerConnection: receiverPC)
        await session.connectionManager.addConnection(restartConnection)

        let restartEvents = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                restartSDP,
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
        #expect(events.isEmpty)
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

        #expect(events.isEmpty)
        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] != nil)
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
        let replayed = RemoteScreenEventBox()
        let listenTask = Task {
            for await event in stream {
                await replayed.append(event)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        listenTask.cancel()

        let events = await replayed.value
        #expect(events.contains { $0.participantId == "echo" && $0.isActive == true })
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
        let replayed = RemoteScreenEventBox()
        let listenTask = Task {
            for await event in stream {
                await replayed.append(event)
                break
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        listenTask.cancel()

        let events = await replayed.value
        #expect(!events.contains { $0.participantId == "echo" && $0.isActive == true })
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

    /// Mirrors a production SFU removed-track offer: camera fully advertised with SSRCs while
    /// the contract screen mid stays `a=sendrecv` with no msid and no ssrc lines (relay sender
    /// removed; transceiver direction never downgraded).
    private func sfuStoppedScreenShareWithBareSendrecvContractMidSDP(
        participant: String = "nudge",
        cameraTrackId: String = "fe1af846-4cbc-4c0b-b278-4f16f91b6983"
    ) -> String {
        """
        v=0
        o=- 358361574959239333 6 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(participant) audio_\(participant)_track
        a=ssrc:1001 cname:\(participant)
        m=video 9 UDP/TLS/RTP/SAVPF 100 101
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(participant) \(cameraTrackId)
        a=ssrc-group:FID 398666556 3165054218
        a=ssrc:398666556 cname:5ZnRdWi+d4QoftSr
        a=ssrc:398666556 msid:\(participant) \(cameraTrackId)
        a=ssrc:3165054218 cname:5ZnRdWi+d4QoftSr
        a=ssrc:3165054218 msid:\(participant) \(cameraTrackId)
        m=video 9 UDP/TLS/RTP/SAVPF 100 101
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendrecv
        a=rtcp-mux
        a=rtcp-rsize
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

    @Test("SDP reconcile does not discover stale screen receiver when SFU only advertises recvonly placeholders")
    func reconcileDoesNotDiscoverStaleScreenReceiverOnRecvonlyPlaceholderOnly() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        let connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        await session.connectionManager.addConnection(connection)
        #expect(connection.remoteScreenTracksByParticipantId.isEmpty)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuRecvonlyPlaceholderConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile discovers live screen receiver on active relay mid after repeated share cycles")
    func reconcileDiscoversUnmappedScreenReceiverOnActiveRelayMid() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")
        guard let screenTransceiver = receiverPC.transceivers.first(where: {
            RTCSession.isScreenShareId($0.receiver.track?.trackId ?? "")
        }),
              let relayTrack = screenTransceiver.receiver.track as? RTCVideoTrack
        else {
            Issue.record("Missing live screen receiver transceiver")
            return
        }
        let relayMid = screenTransceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayTrackId = relayTrack.trackId

        let connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        await session.connectionManager.addConnection(connection)
        #expect(connection.remoteScreenTracksByParticipantId.isEmpty)

        let activeRelaySDP = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:\(relayMid)
        a=sendrecv
        a=msid:screen_nudge \(relayTrackId)
        """

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                activeRelaySDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] != nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == true })
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

    /// Production removed-track offers can leave the contract mid as a zombie `a=sendrecv`
    /// section with no msid/ssrc (relay sender removed, direction never downgraded). That bare
    /// section must not read as an active screen, or the viewer keeps the screen-share UI after
    /// the sharer stops.
    @Test("SDP reconcile removes stale screen receiver when stop leaves bare sendrecv contract mid")
    func reconcileRemovesScreenReceiverWhenStopLeavesBareSendrecvContractMid() async throws {
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
                sfuStoppedScreenShareWithBareSendrecvContractMidSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("relay screen mid parser ignores bare sendrecv sections without msid or ssrc")
    func parserIgnoresBareSendrecvRelaySectionWithoutMediaIdentity() {
        let zombieStopOffer = sfuStoppedScreenShareWithBareSendrecvContractMidSDP()
        #expect(RTCSession.sfuRelayIncomingScreenShareVideoMids(in: zombieStopOffer).isEmpty)
        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: zombieStopOffer).isEmpty)
    }

    @Test("1:1 SFU screen mid parser accepts UUID-only contract screen relay")
    func oneToOneSfuScreenMidParserAcceptsUuidOnlyContractScreenRelay() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:nudge 5bde4c9c-062b-44d5-ad82-0e676792e240
        a=ssrc:2321476603 msid:nudge 5bde4c9c-062b-44d5-ad82-0e676792e240
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=sendrecv
        a=msid:5a6586e7-9755-4537-b9d8-819bef0c1a30 f9c2c636-4745-4718-9384-fbd9fcaa9d1b
        a=ssrc:2252254230 msid:5a6586e7-9755-4537-b9d8-819bef0c1a30 f9c2c636-4745-4718-9384-fbd9fcaa9d1b
        """

        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.oneToOneSfuIncomingScreenShareVideoMids(in: sdp) == Set(["2"]))
    }

    @Test("SDP reconcile does not rediscover stale screen receiver after stop on a later recvonly placeholder")
    func reconcileDoesNotRediscoverStaleScreenReceiverAfterStopOnLaterReconcile() async throws {
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

        let stopSDP = sfuStoppedScreenShareWithActiveCameraSDP()
        _ = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                stopSDP,
                connectionId: conferenceConnectionId
            )
        }

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                stopSDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(updated?.suppressedRemoteScreenShareParticipantIds.contains("nudge") == true)
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile skips stale remote screen discovery while local screen share is active")
    func reconcileSkipsRemoteScreenDiscoveryWhileLocalShareActive() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        connection.localScreenTrack = makeScreenVideoTrack(trackId: "screen_echo_\(conferenceConnectionId)")
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuRecvonlyPlaceholderConferenceSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile clears mapping during preempt wait when SFU stop-forwards recvonly screen mid")
    func reconcileClearsMappingDuringPreemptWaitOnRecvonlyStopForward() async throws {
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
        connection.remoteScreenShareStopRequestedParticipantKeys.insert("nudge")
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

    @Test("SDP reconcile clears screen mapping when stop-forward SDP has recvonly placeholder only")
    func reconcileClearsScreenMappingOnRecvonlyStopForwardWithoutActiveAdvertisement() async throws {
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
        connection.remoteScreenShareStopRequestedParticipantKeys.insert("nudge")
        await session.connectionManager.addConnection(connection)

        let stopForwardSDP = sfuStoppedScreenShareWithActiveCameraSDP()

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                stopForwardSDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile clears relay screen mapping after preempt when SFU leaves stale UUID relay mid")
    func reconcileClearsRelayScreenAfterPreemptWithStaleUuidRelayMid() async throws {
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
        connection.remoteScreenShareStopRequestedParticipantKeys.insert("nudge")
        await session.connectionManager.addConnection(connection)

        await session.testing_seedRemoteScreenIngressFlatSinceForTests(
            key: "\(conferenceConnectionId)|nudge",
            since: Date().addingTimeInterval(-4)
        )
        await session.testing_seedLastInboundScreenVideoCountersForTests(
            connectionId: conferenceConnectionId,
            audioPacketsReceived: 100,
            packetsReceived: 50,
            framesReceived: 10,
            framesDecoded: 10
        )

        let staleRelaySDP = """
        v=0
        o=- 5040176827671334280 7 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:nudge audio_nudge_track
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:nudge fe1af846-4cbc-4c0b-b278-4f16f91b6983
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendrecv
        a=msid:1b66c30c-f7d2-465d-a5e0-35ec1aabe1b8 70b2b9b8-21ae-4666-b292-bd7abb0cc42b
        """

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                staleRelaySDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(updated?.remoteScreenShareStopRequestedParticipantKeys.contains("nudge") == false)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.isActive == true })
    }

    @Test("SDP reconcile clears UUID relay mapping when all remote video mids deactivate")
    func reconcileClearsUuidRelayMappingWhenAllVideoMidsDeactivate() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        let relayTrackId = "680ea869-d318-4411-80e0-b07bcb07e91b"
        connection.remoteScreenTracksByParticipantId["nudge"] = makeScreenVideoTrack(trackId: relayTrackId)
        connection.remoteVideoTracksByParticipantId["nudge"] = makeCameraVideoTrack(
            trackId: "fe1af846-4cbc-4c0b-b278-4f16f91b6983"
        )
        await session.connectionManager.addConnection(connection)

        let allInactiveSDP = """
        v=0
        o=- 5040176827671334280 8 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2 3
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=inactive
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:3
        a=inactive
        """

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                allInactiveSDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile clears UUID alias screen mappings and does not readvertise after stop")
    func reconcileClearsAliasScreenMappingsWithoutReadvertiseAfterStop() async throws {
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
        let cameraTrack = makeCameraVideoTrack(trackId: "fe1af846-4cbc-4c0b-b278-4f16f91b6983")
        connection.remoteScreenTracksByParticipantId["nudge"] = screenTrack
        connection.remoteScreenTracksByParticipantId["bd519746-04a4-46ed-b495-52a390d188bf"] = screenTrack
        connection.remoteVideoTracksByParticipantId["nudge"] = cameraTrack
        connection.remoteVideoTracksByParticipantId["bd519746-04a4-46ed-b495-52a390d188bf"] = cameraTrack
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                sfuStoppedScreenShareWithActiveCameraSDP(),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(updated?.remoteScreenTracksByParticipantId["bd519746-04a4-46ed-b495-52a390d188bf"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == false })
        #expect(!events.contains { $0.isActive == true })
    }

    @Test("SDP reconcile maps screen receiver on earlier video slot when stale transceivers accumulated")
    func reconcileMapsScreenReceiverWhenStaleTransceiversAccumulated() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        guard let screenTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { RTCSession.isScreenShareId($0.trackId) }
        ) else {
            Issue.record("Missing live screen receiver")
            return
        }

        let staleTransceiver = receiverPC.addTransceiver(of: .video)
        staleTransceiver?.setDirection(.inactive, error: nil)

        let connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(participant: "nudge"),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"]?.trackId == screenTrack.trackId)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile reclaims camera mapping when screen track landed on screen slot transceiver")
    func reconcileReclaimsCameraMappingOnScreenSlotTransceiver() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        guard let screenTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { RTCSession.isScreenShareId($0.trackId) }
        ) else {
            Issue.record("Missing live screen receiver")
            return
        }

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        connection.remoteVideoTracksByParticipantId["nudge"] = screenTrack
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(participant: "nudge"),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"]?.trackId == screenTrack.trackId)
        #expect(updated?.remoteVideoTracksByParticipantId["nudge"] == nil)
        #expect(events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }

    @Test("SDP reconcile removes stored 1:1 SFU screen share when SFU stops advertising it")
    func reconcileRemovesOneToOneSfuScreenShareWhenSDPStopsAdvertising() async throws {
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
        let call = try Call(
            sharedCommunicationId: oneToOneId,
            channelWireId: oneToOneId.ensureIRCChannel,
            sender: sender,
            recipients: [recipient]
        )

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

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                cameraOnlyConferenceSDP(),
                connectionId: oneToOneId
            )
        }

        let updated = await session.connectionManager.findConnection(with: oneToOneId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] == nil)
        #expect(events.contains {
            $0.participantId == "echo" && $0.isActive == false
        })
    }
}
#endif

@Suite
struct ScreenShareOfferTimingTests {
    @Test("ReplayKit app-screen capture defers SFU renegotiation until broadcast starts")
    func replayKitDefersOfferUntilCaptureReady() {
        #expect(RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .appScreen))
        #expect(RTCSession.shouldDeferScreenShareRenegotiationUntilCaptureReady(target: .androidScreen))
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

    @Test("remote sending video mid parser detects active inbound camera offers")
    func parserDetectsRemoteSendingVideoMids() {
        let placeholder = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=recvonly
        """
        #expect(RTCSession.remoteSendingVideoMids(in: placeholder).isEmpty)
        #expect(RTCSession.remoteSdpIncludesInboundVideoFromPeer(in: placeholder) == false)

        let active = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=msid:echo eb44d10a-381a-449f-ad1f-4a16104a2486
        """
        #expect(RTCSession.remoteSendingVideoMids(in: active) == ["1"])
        #expect(RTCSession.remoteSdpIncludesInboundVideoFromPeer(in: active) == true)
    }

    @Test("relay UUID second video mid is not treated as active screen share")
    func parserIgnoresRelayUuidSecondVideoMid() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=msid:streamId_nudge 5e5c0ca1-1111-2222-3333-444444444444
        m=video 9 UDP/TLS/RTP/SAVPF 97
        a=mid:2
        a=sendrecv
        a=msid:159bb806-e3ee-410e-b28a-c0642950f15e 8726d5a1-397a-4847-8d3a-48644fcf0afc
        """

        #expect(RTCSession.sfuRelayIncomingScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.activeScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.screenShareVideoMids(in: sdp).isEmpty)
    }

    @Test("SFU camera-labelled later video mid is not treated as screen share")
    func parserIgnoresCameraLabelledLaterVideoMid() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=mid:1
        a=sendrecv
        a=msid:frank 4b46a924-f24a-4456-8ad7-2398e3d4e727
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:2
        a=sendrecv
        a=msid:echo audio_echo_493b6051-39f0-493d-aace-7683f2bfa9e2
        m=video 9 UDP/TLS/RTP/SAVPF 97
        a=mid:3
        a=sendrecv
        a=msid:echo video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2
        """

        #expect(RTCSession.sfuRelayIncomingScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.screenShareVideoMids(in: sdp).isEmpty)
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

    @Test("remote active incoming screen mids require both screen msid and remote send direction")
    func remoteActiveIncomingScreenShareVideoMidsRequiresRemoteSend() {
        let activeRemoteScreenOffer = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=sendrecv
        a=msid:screen_nudge screen_nudge_track
        """

        let inactiveRemoteScreenOffer = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=inactive
        a=msid:screen_nudge screen_nudge_track
        """

        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: activeRemoteScreenOffer) == ["2"])
        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: inactiveRemoteScreenOffer).isEmpty)
    }

    @Test("relay UUID video after repeated share cycles is not treated as screen")
    func remoteActiveIncomingScreenShareVideoMidsIgnoresRelayMidAfterReuse() {
        let thirdShareRelayOffer = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:3
        a=sendrecv
        a=msid:nudge 419f68a9-c266-4da0-b855-f81a39c8b88a
        """

        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: thirdShareRelayOffer).isEmpty)
        #expect(RTCSession.sfuRelayIncomingScreenShareVideoMids(in: thirdShareRelayOffer).isEmpty)
    }

    #if canImport(WebRTC) && !os(Android)
    @Test("inbound screen transceiver upgrade only applies to inactive viewer slots")
    func inboundScreenTransceiverUpgradeSkipsLocalSharer() {
        #expect(
            RTCSession.shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
                localScreenShareActive: true,
                senderTrackId: "screen_nudge_track",
                receiverTrackId: "relay-uuid",
                cameraTrackIds: [],
                transceiverDirection: .inactive
            ) == false
        )
        #expect(
            RTCSession.shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
                localScreenShareActive: false,
                senderTrackId: "screen_nudge_track",
                receiverTrackId: "relay-uuid",
                cameraTrackIds: [],
                transceiverDirection: .sendOnly
            ) == false
        )
        #expect(
            RTCSession.shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
                localScreenShareActive: false,
                senderTrackId: nil,
                receiverTrackId: "relay-uuid",
                cameraTrackIds: [],
                transceiverDirection: .inactive
            ) == true
        )
        #expect(
            RTCSession.shouldUpgradeAppleScreenTransceiverForInboundScreenReceive(
                localScreenShareActive: false,
                senderTrackId: nil,
                receiverTrackId: "screen_nudge_493b6051-39f0-493d-aace-7683f2bfa9e2",
                cameraTrackIds: ["video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2"],
                transceiverDirection: .sendRecv
            ) == true
        )
    }
    #endif

    @Test("answer SDP normalizer makes stale screen-share mids compatible with local offer")
    func answerSdpNormalizerMakesStaleScreenMidsCompatible() {
        let localOffer = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=sendonly
        a=msid:screen_nudge screen_nudge_track
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:3
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:4
        a=recvonly
        """
        let sfuAnswerWithStaleScreenState = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:3
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:4
        a=sendonly
        """

        let normalized = RTCSession.normalizeAnswerVideoDirectionsForLocalOffer(
            answerSdp: sfuAnswerWithStaleScreenState,
            localOfferSdp: localOffer
        )

        #expect(direction(forMid: "2", in: normalized) == "recvonly")
        #expect(direction(forMid: "3", in: normalized) == "sendonly")
        #expect(direction(forMid: "4", in: normalized) == "sendonly")
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

    @Test("relay-style SDP parser ignores echo camera plus UUID relay video section")
    func parserIgnoresEchoRelayUuidVideoSection() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:echo 948ca83d-76ef-4ca2-b370-6a405d2f5781
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:2
        a=sendrecv
        a=msid:f4c7c425-c58e-4e7b-bbb2-aa51116558f2 da59f5a0-6c18-45f4-a8a7-df01edab5918
        """
        let shares = RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge"
        ) { label in
            label == "echo" ? "echo" : nil
        }
        #expect(shares.isEmpty)
        #expect(RTCSession.sfuRelayIncomingScreenShareVideoMids(in: sdp).isEmpty)
        #expect(RTCSession.remoteActiveIncomingScreenShareVideoMids(in: sdp).isEmpty)
    }

    @Test("relay-style SDP parser ignores camera-labelled participant video")
    func parserIgnoresCameraLabelledParticipantVideo() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:1
        a=sendrecv
        a=msid:frank 4b46a924-f24a-4456-8ad7-2398e3d4e727
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:2
        a=sendrecv
        a=msid:echo audio_echo_493b6051-39f0-493d-aace-7683f2bfa9e2
        m=video 9 UDP/TLS/RTP/SAVPF 100
        a=mid:3
        a=sendrecv
        a=msid:echo video_echo_493b6051-39f0-493d-aace-7683f2bfa9e2
        """
        let shares = RTCSession.advertisedRelayStyleRemoteScreenShares(
            in: sdp,
            localParticipantId: "nudge"
        ) { label in
            label == "echo" ? "echo" : nil
        }

        #expect(shares.isEmpty)
    }

}

#if canImport(WebRTC) && !os(Android)
extension ScreenShareRenegotiationTests {
    @Test("SDP reconcile removes UUID relay screen mapping for active UUID relay offer")
    func reconcileRemovesUuidRelayScreenMappingForActiveUuidRelayOffer() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let sender = try makePeerConnection()
        let receiverPC = try makePeerConnection()
        let cameraTrack = makeCameraVideoTrack(trackId: "30cb1cab-3e0e-425f-85f3-b4e88c468fa6")
        let relayScreenTrack = makeScreenVideoTrack(trackId: "6377c217-3137-41e4-9aff-393e23b9e312")
        guard sender.add(cameraTrack, streamIds: ["echo"]) != nil,
              sender.add(
                  relayScreenTrack,
                  streamIds: ["891d8941-5479-4d1e-9c5e-be16f3135015"]
              ) != nil
        else {
            throw TestError.negotiationFailed("Failed to add echo relay sender tracks")
        }

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )
        let offer = try await sender.offer(for: offerConstraints)
        try await sender.setLocalDescription(offer)
        try await receiverPC.setRemoteDescription(offer)

        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "true",
            ],
            optionalConstraints: nil
        )
        let answer = try await receiverPC.answer(for: answerConstraints)
        try await receiverPC.setLocalDescription(answer)
        try await sender.setRemoteDescription(answer)

        guard let liveRelayTrack = receiverPC.transceivers.compactMap({ transceiver -> RTCVideoTrack? in
            guard transceiver.mediaType == .video,
                  let track = transceiver.receiver.track as? RTCVideoTrack,
                  track.trackId == relayScreenTrack.trackId
            else { return nil }
            return track
        }).first else {
            Issue.record("Missing live UUID relay screen receiver")
            return
        }

        var connection = try await makeConferenceConnection(peerConnection: receiverPC)
        connection.remoteVideoTracksByParticipantId["echo"] = cameraTrack
        connection.remoteScreenTracksByParticipantId["echo"] = liveRelayTrack
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                offer.sdp,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["echo"] == nil)
        #expect(events.contains { $0.participantId == "echo" && $0.isActive == false })
    }

    @Test("relay-style SDP parser ignores second active video section for same participant")
    func parserIgnoresRelayStyleSecondVideoSection() {
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
        #expect(shares.isEmpty)
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

    @Test("exclusive screen share policy applies to conference group and 1:1 SFU rooms")
    func shouldEnforceExclusiveRoomScreenShare() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "alice", deviceId: "device")
        let recipient = try Call.Participant(secretName: "bob", nickname: "bob", deviceId: "device")

        var conference = try Call(
            sharedCommunicationId: "#conf-room",
            channelWireId: "#conf-room",
            sender: sender,
            recipients: [recipient]
        )
        conference.conferencePassword = "secret"
        #expect(RTCSession.shouldEnforceExclusiveRoomScreenShare(call: conference))

        var group = try Call(
            sharedCommunicationId: "#group-room",
            channelWireId: "#group-room",
            sender: sender,
            recipients: [recipient]
        )
        #expect(RTCSession.shouldEnforceExclusiveRoomScreenShare(call: group))

        let wireId = UUID().uuidString
        var oneToOneSfu = try Call(
            sharedCommunicationId: wireId,
            channelWireId: wireId,
            sender: sender,
            recipients: [recipient]
        )
        #expect(RTCSession.shouldEnforceExclusiveRoomScreenShare(call: oneToOneSfu))

        var plainP2P = try Call(
            sharedCommunicationId: UUID().uuidString,
            sender: sender,
            recipients: [recipient]
        )
        #expect(!RTCSession.shouldEnforceExclusiveRoomScreenShare(call: plainP2P))
    }

    @Test("exclusive screen share stop wait uses longer timeout for SFU rooms")
    func exclusiveScreenShareStopWaitTimeout() throws {
        let sender = try Call.Participant(secretName: "alice", nickname: "alice", deviceId: "device")
        let recipient = try Call.Participant(secretName: "bob", nickname: "bob", deviceId: "device")

        let wireId = UUID().uuidString
        var oneToOneSfu = try Call(
            sharedCommunicationId: wireId,
            channelWireId: wireId,
            sender: sender,
            recipients: [recipient]
        )
        #expect(RTCSession.exclusiveScreenShareStopWaitTimeout(for: oneToOneSfu) == 20.0)

        var plainP2P = try Call(
            sharedCommunicationId: UUID().uuidString,
            sender: sender,
            recipients: [recipient]
        )
        #expect(RTCSession.exclusiveScreenShareStopWaitTimeout(for: plainP2P) == 8.0)
    }

    @Test("handleInboundScreenSharePreempt stops local capture for the targeted participant")
    func handleInboundScreenSharePreemptStopsLocalShare() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.localScreenTrack = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        var call = connection.call
        call.metadata = try BinaryEncoder().encode(
            ScreenSharePreemptCommand(targetParticipantSecretName: "nudge")
        )
        await session.handleInboundScreenSharePreempt(call: call, sfuIdentity: conferenceConnectionId)

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.localScreenTrack == nil)
    }

    @Test("handleInboundScreenSharePreempt resolves connection via slug wire id")
    func handleInboundScreenSharePreemptResolvesSlugWireId() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let roomUUID = "493b6051-39f0-493d-aace-7683f2bfa9e2"
        let wireRoute = "#broken_\(roomUUID)"
        var call = try makeConferenceCall()
        call.sharedCommunicationId = roomUUID
        call.channelWireId = wireRoute

        var connection = try await makeConferenceConnection(
            peerConnection: try makePeerConnection(),
            connectionId: roomUUID,
            call: call
        )
        connection.localScreenTrack = makeScreenVideoTrack()
        await session.connectionManager.addConnection(connection)

        var preemptCall = call
        preemptCall.metadata = try BinaryEncoder().encode(
            ScreenSharePreemptCommand(targetParticipantSecretName: "nudge")
        )
        await session.handleInboundScreenSharePreempt(call: preemptCall, sfuIdentity: wireRoute)

        let updated = await session.connectionManager.findConnection(with: roomUUID)
        #expect(updated?.localScreenTrack == nil)
    }

    @Test("supersedeRemoteScreenShares emits inactive events for stale sharers")
    func supersedeRemoteScreenSharesEmitsInactiveEvents() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["alice"] = makeScreenVideoTrack(trackId: "screen_alice")
        connection.remoteScreenTracksByParticipantId["bob"] = makeScreenVideoTrack(trackId: "screen_bob")
        await session.connectionManager.addConnection(connection)

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.supersedeRemoteScreenShares(
                connectionId: conferenceConnectionId,
                keepingParticipantId: "bob"
            )
        }

        #expect(events.contains { $0.participantId == "alice" && $0.isActive == false })
        #expect(!events.contains { $0.participantId == "bob" })
    }

    @Test("alice bob alice handoff clears suppression and remaps restarted share")
    func aliceBobAliceHandoffRemapsRestartedShare() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        var connection = try await makeConferenceConnection(peerConnection: try makePeerConnection())
        connection.remoteScreenTracksByParticipantId["alice"] = makeScreenVideoTrack(trackId: "screen_alice_1")
        await session.connectionManager.addConnection(connection)

        let bobTakeoverEvents = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(participant: "bob"),
                connectionId: conferenceConnectionId
            )
        }
        #expect(bobTakeoverEvents.contains { $0.participantId == "alice" && $0.isActive == false }
            || bobTakeoverEvents.contains { $0.participantId == "bob" && $0.isActive == true })

        if var afterBob = await session.connectionManager.findConnection(with: conferenceConnectionId) {
            afterBob.remoteScreenTracksByParticipantId.removeValue(forKey: "alice")
            afterBob.suppressedRemoteScreenShareParticipantIds.insert("alice")
            afterBob.remoteScreenTracksByParticipantId["bob"] = makeScreenVideoTrack(trackId: "screen_bob_1")
            await session.connectionManager.updateConnection(id: conferenceConnectionId, with: afterBob)
        }

        if var beforeAliceRestart = await session.connectionManager.findConnection(with: conferenceConnectionId) {
            beforeAliceRestart.remoteScreenTracksByParticipantId["alice"] = makeScreenVideoTrack(trackId: "screen_alice_2")
            await session.connectionManager.updateConnection(id: conferenceConnectionId, with: beforeAliceRestart)
        }

        let restartEvents = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                screenShareConferenceSDP(participant: "alice"),
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["alice"] != nil)
        #expect(updated?.suppressedRemoteScreenShareParticipantIds.contains("alice") == false)
        #expect(restartEvents.contains { $0.participantId == "bob" && $0.isActive == false })
        #expect(!restartEvents.contains { $0.participantId == "alice" && $0.isActive == false })
    }

    @Test("local screen share blocks stale remote screen remap during handoff")
    func localScreenShareBlocksStaleRemoteScreenRemap() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        defer { Task { await session.shutdown(with: nil) } }
        await configureGroupSession(session)

        let receiverPC = try makePeerConnection()
        _ = try await negotiateScreenShareOntoReceiver(receiver: receiverPC, participant: "nudge")

        var connection = try await makeViewerConferenceConnection(peerConnection: receiverPC)
        guard let staleTrack = receiverPC.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first(
            where: { $0.readyState != .ended }
        ) else {
            Issue.record("Missing live relay receiver")
            return
        }
        connection.localScreenTrack = makeScreenVideoTrack(trackId: "screen_echo_\(conferenceConnectionId)")
        connection.remoteScreenShareStopRequestedParticipantKeys.insert("nudge")
        connection.suppressedRemoteScreenShareParticipantIds.insert("nudge")
        await session.connectionManager.addConnection(connection)

        let staleRelaySDP = """
        v=0
        o=- 5040176827671334280 8 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:nudge audio_nudge_track
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:nudge fe1af846-4cbc-4c0b-b278-4f16f91b6983
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendrecv
        a=msid:34006f2b-9bc4-4472-9add-5a915a9f2cef 86be887a-16e0-4bed-a9cf-6acf02de5698
        """

        let events = try await captureRemoteScreenEvents(from: session) {
            await session.reconcileAppleRemoteScreenTracksAfterSetRemoteSDP(
                staleRelaySDP,
                connectionId: conferenceConnectionId
            )
        }

        let updated = await session.connectionManager.findConnection(with: conferenceConnectionId)
        #expect(updated?.remoteScreenTracksByParticipantId["nudge"] == nil)
        #expect(!events.contains { $0.participantId == "nudge" && $0.isActive == true })
    }
}
#endif

extension ScreenShareSdpParserTests {
    @Test("stale inactive screen-share events are ignored for non-active sharers")
    func staleInactiveScreenShareEventsAreIgnoredForNonActiveSharers() {
        #expect(RTCSession.shouldAcceptRemoteScreenShareEnd(
            activeParticipantId: nil,
            endedParticipantId: "alice"
        ))
        #expect(RTCSession.shouldAcceptRemoteScreenShareEnd(
            activeParticipantId: "screen_bob_",
            endedParticipantId: "bob"
        ))
        #expect(RTCSession.shouldAcceptRemoteScreenShareEnd(
            activeParticipantId: "bob_550e8400-e29b-41d4-a716-446655440000",
            endedParticipantId: "screen_bob"
        ))
        #expect(!RTCSession.shouldAcceptRemoteScreenShareEnd(
            activeParticipantId: "bob",
            endedParticipantId: "alice"
        ))
    }
}

private actor RemoteScreenEventBox {
    var value: [RemoteScreenTrackEvent] = []

    func append(_ event: RemoteScreenTrackEvent) {
        value.append(event)
    }
}
