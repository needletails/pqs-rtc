import Foundation
import Testing
import DoubleRatchetKit
#if os(macOS)
import WebRTC

@testable import PQSRTC

/// ScreenCaptureKit takes 0.1-1 s to start. A stop (or call end) in that window must win, and
/// the start must not write back a connection copy taken before the wait.
@Suite(.serialized)
struct StopDuringMacScreenCaptureStartTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [Call] = []
        private(set) var sfuFlags: [PacketFlag] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws { sfuFlags.append(packet.flag) }
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws { negotiated.append(call) }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    /// Holds the ScreenCaptureKit start until the test opens it.
    actor Gate {
        private var entered = false
        private var opened = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var openWaiter: CheckedContinuation<Void, Never>?

        func pass() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            guard !opened else { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        func open() {
            opened = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    actor Outcome {
        private(set) var finished = false
        private(set) var error: String?

        func finish(_ error: Error?) {
            finished = true
            self.error = error.map { String(describing: $0) }
        }
    }

    actor Recorder {
        private(set) var values: [Bool] = []
        func append(_ value: Bool) { values.append(value) }
    }

    private func waitUntil(
        timeoutSeconds: Double,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    /// An SFU room whose join offer is answered (stable), with a second PeerConnection as the SFU.
    private func makeStableSfuRoom(
        transport: Transport
    ) async throws -> (RTCSession, RTCConnection, WebRTC.RTCPeerConnection) {
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        var call = try #require(await transport.negotiated.last)

        let sfuKeyStore = KeyManager()
        let sfuIdentity = try await sfuKeyStore.generateSenderIdentity(connectionId: sfuRecipientId, secretName: sfuRecipientId)
        call.signalingIdentityProps = try #require(await sfuIdentity.sessionIdentity.props(symmetricKey: sfuIdentity.symmetricKey))
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)
        try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId: sfuRecipientId, updatedCall: call)
        let joinOfferSent = await waitUntil(timeoutSeconds: 5.0) { await transport.sfuFlags.contains(.offer) }
        try #require(joinOfferSent)

        let connection = try #require(await session.connectionManager.findConnection(with: sfuRecipientId))
        let clientPC = connection.peerConnection
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let sfuPC = try #require(RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil))
        try await sfuPC.setRemoteDescription(try #require(clientPC.localDescription))
        let joinAnswer = try await sfuPC.answer(for: constraints)
        try await sfuPC.setLocalDescription(joinAnswer)
        try await clientPC.setRemoteDescription(joinAnswer)
        try #require(clientPC.signalingState == .stable)
        return (session, connection, sfuPC)
    }

    @Test
    func stopWhileCaptureIsStarting_doesNotPublishShare() async throws {
        let transport = Transport()
        let (session, connection, sfuPC) = try await makeStableSfuRoom(transport: transport)
        defer { sfuPC.close() }
        let connectionId = connection.id

        let states = Recorder()
        let stateStream = await session.localScreenShareStateStream()
        let stateTask = Task { for await isSharing in stateStream { await states.append(isSharing) } }
        try #require(await waitUntil(timeoutSeconds: 5.0) { await states.values.isEmpty == false })

        let gate = Gate()
        MacScreenCaptureSource.startCaptureForTesting = { await gate.pass() }
        defer { MacScreenCaptureSource.startCaptureForTesting = nil }

        let outcome = Outcome()
        let start = Task {
            do {
                try await session.addScreenTrackToStream(target: .entireScreen(displayID: 1), connectionId: connectionId)
                await outcome.finish(nil)
            } catch {
                await outcome.finish(error)
            }
        }
        await gate.waitUntilEntered()

        // The user stops sharing while ScreenCaptureKit is still starting.
        await session.removeScreenTrackFromStream(connectionId: connectionId)
        await gate.open()

        let finished = await waitUntil(timeoutSeconds: 10.0) { await outcome.finished }
        try #require(finished, "Screen share start did not finish")
        _ = await waitUntil(timeoutSeconds: 0.5) { await states.values.contains(true) }

        let latest = try #require(await session.connectionManager.findConnection(with: connectionId))
        let screenSenders = latest.peerConnection.senders.filter {
            $0.track?.trackId.hasPrefix(RTCSession.screenTrackPrefix) == true
        }
        #expect(latest.localScreenTrack == nil, "The share went live after the user stopped it during capture start")
        #expect(screenSenders.isEmpty, "A screen sender was added after the user stopped the share")
        #expect(await states.values.contains(true) == false, "The UI was told the stopped share is live")
        #expect(await outcome.error != nil, "Start reported success for a share the user stopped")

        stateTask.cancel()
        start.cancel()
        await session.shutdown(with: nil)
    }

    @Test
    func connectionChangeWhileCaptureIsStarting_isKept() async throws {
        let transport = Transport()
        let (session, connection, sfuPC) = try await makeStableSfuRoom(transport: transport)
        defer { sfuPC.close() }
        let connectionId = connection.id

        let gate = Gate()
        MacScreenCaptureSource.startCaptureForTesting = { await gate.pass() }
        defer { MacScreenCaptureSource.startCaptureForTesting = nil }

        let outcome = Outcome()
        let start = Task {
            do {
                try await session.addScreenTrackToStream(target: .entireScreen(displayID: 1), connectionId: connectionId)
                await outcome.finish(nil)
            } catch {
                await outcome.finish(error)
            }
        }
        await gate.waitUntilEntered()

        // While ScreenCaptureKit starts, SFU renegotiation maps a remote participant's camera.
        var changed = try #require(await session.connectionManager.findConnection(with: connectionId))
        let bobCamera = RTCSession.factory.videoTrack(with: RTCSession.factory.videoSource(), trackId: "bob_camera")
        changed.remoteVideoTracksByParticipantId["bob"] = bobCamera
        await session.connectionManager.updateConnection(id: connectionId, with: changed)
        await gate.open()

        let finished = await waitUntil(timeoutSeconds: 10.0) { await outcome.finished }
        try #require(finished, "Screen share start did not finish")
        let startError = await outcome.error
        #expect(startError == nil, "Screen share start failed: \(startError ?? "")")

        let latest = try #require(await session.connectionManager.findConnection(with: connectionId))
        #expect(latest.localScreenTrack != nil)
        #expect(
            latest.remoteVideoTracksByParticipantId["bob"] === bobCamera,
            "Starting the share wrote back a connection copy taken before ScreenCaptureKit started"
        )

        start.cancel()
        await session.shutdown(with: nil)
    }
}
#endif
