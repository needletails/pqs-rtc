import Foundation
import Testing
import DoubleRatchetKit

@testable import PQSRTC

/// SFU media bootstrap suspends several times (key lookups, connection lookup, iOS audio prep)
/// before it creates the room's PeerConnection. A user who leaves in one of those gaps must not
/// get a PeerConnection with live local media for the call they already left.
@Suite(.serialized)
struct LeaveDuringGroupMediaBootstrapTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [Call] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {}
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws { negotiated.append(call) }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}
    }

    /// Holds the bootstrap at its suspension until the test opens it.
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

    @Test
    func leaveWhileBootstrapIsSuspended_createsNoPeerConnection() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        var call = try #require(await transport.negotiated.last)

        // SFU registration reply.
        let sfuKeyStore = KeyManager()
        let sfuIdentity = try await sfuKeyStore.generateSenderIdentity(connectionId: sfuRecipientId, secretName: sfuRecipientId)
        call.signalingIdentityProps = try #require(await sfuIdentity.sessionIdentity.props(symmetricKey: sfuIdentity.symmetricKey))
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)

        let group = try #require(await session.groupCallForRoom(sfuRecipientId))
        let gate = Gate()
        group.willCreateMediaForTesting = { await gate.pass() }

        let outcome = Outcome()
        let registrationReply = call
        let bootstrap = Task {
            do {
                try await session.beginGroupCallMediaAfterSfuRegistrationIfNeeded(
                    sfuRecipientId: sfuRecipientId,
                    updatedCall: registrationReply)
                await outcome.finish(nil)
            } catch {
                await outcome.finish(error)
            }
        }
        await gate.waitUntilEntered()

        // The user leaves while the bootstrap is suspended; the leave runs to completion.
        try await session.leave(sfuRecipientId: sfuRecipientId, call: await group.currentCall)
        #expect(await session.groupCallForRoom(sfuRecipientId) == nil)
        await gate.open()

        _ = await waitUntil(timeoutSeconds: 10.0) {
            if await outcome.finished { return true }
            return await session.hasConnection(id: sfuRecipientId)
        }
        let leakedConnection = await session.hasConnection(id: sfuRecipientId)
        let finished = await outcome.finished
        let bootstrapError = await outcome.error
        #expect(!leakedConnection, "Bootstrap created a PeerConnection with local media for a group the user already left")
        #expect(finished, "Bootstrap did not finish after the group ended")
        #expect(bootstrapError == nil, "Bootstrap failed after the group ended: \(bootstrapError ?? "")")

        bootstrap.cancel()
        await session.shutdown(with: nil)
    }

    /// iOS suspends once more on the main actor for audio prep; that hop cannot run on macOS.
    @Test
    func iosAudioPrepHop_rechecksGroupBeforeCreatingPeerConnection() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+GroupCall.swift"),
            encoding: .utf8
        )
        let body = try SourceContract.sourceBody(of: "beginGroupCallMediaAfterSfuRegistrationIfNeeded", in: source)
        let audioPrep = try #require(body.range(of: "try await MainActor.run"))
        let createPeerConnection = try #require(body.range(of: "try await createPeerConnection("))
        let recheck = try #require(body.range(
            of: "guard groupMediaBootstrapIsLive(group, room: normalizedLookup) else { return }",
            range: audioPrep.upperBound..<body.endIndex))
        #expect(recheck.upperBound < createPeerConnection.lowerBound)
    }
}
