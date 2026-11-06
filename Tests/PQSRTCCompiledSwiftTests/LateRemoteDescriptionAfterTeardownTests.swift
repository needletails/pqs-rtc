import Foundation
import ObjectiveC
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// Withholds one peer connection's `setRemoteDescription` completion after WebRTC has applied the
/// description, so `setRemote` stays suspended there while the test tears the call down.
private final class HeldSetRemoteDescription: @unchecked Sendable {
    typealias Completion = @convention(block) (NSError?) -> Void
    private typealias Original = @convention(c) (AnyObject, Selector, WebRTC.RTCSessionDescription, @escaping Completion) -> Void

    enum HoldError: Error {
        case missingMethod
    }

    private let lock = NSLock()
    private let method: Method
    private let originalIMP: IMP
    private var held: (completion: Completion, error: NSError?)?
    private var appliedWaiter: CheckedContinuation<Void, Never>?

    init(peerConnection target: WebRTC.RTCPeerConnection) throws {
        let selector = NSSelectorFromString("setRemoteDescription:completionHandler:")
        guard let method = class_getInstanceMethod(WebRTC.RTCPeerConnection.self, selector) else {
            throw HoldError.missingMethod
        }
        self.method = method
        self.originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: Original.self)
        let replacement: @convention(block) (AnyObject, WebRTC.RTCSessionDescription, @escaping Completion) -> Void = {
            [weak self, weak target] peerConnection, sdp, completion in
            guard let self, peerConnection === target else {
                original(peerConnection, selector, sdp, completion)
                return
            }
            original(peerConnection, selector, sdp) { error in self.hold(completion, error: error) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    func restore() {
        method_setImplementation(method, originalIMP)
    }

    /// Returns once WebRTC has applied the description; `setRemote` is still suspended.
    func waitUntilApplied() async -> NSError? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyApplied = lock.withLock {
                if held != nil { return true }
                appliedWaiter = continuation
                return false
            }
            if alreadyApplied { continuation.resume() }
        }
        return lock.withLock { held?.error }
    }

    /// Lets `setRemote` resume.
    func release() {
        let released = lock.withLock {
            let value = held
            held = nil
            return value
        }
        released?.completion(released?.error)
    }

    private func hold(_ completion: @escaping Completion, error: NSError?) {
        let waiter = lock.withLock {
            held = (completion, error)
            let waiter = appliedWaiter
            appliedWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
}

/// A remote description can land after its call was torn down: `setRemote` awaits
/// `setRemoteDescription` and the reconcile passes after it, and a hangup can run meanwhile.
/// The late `setRemote` must not re-create the per-connection state the teardown cleared, or the
/// next call's early ICE candidates are applied before that call's own remote description.
@Suite(.serialized)
struct LateRemoteDescriptionAfterTeardownTests {
    actor TestTransportEvents: RTCTransportEvents {
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

    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private let events = TestTransportEvents()

    private func makePeerConnection() throws -> WebRTC.RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return peerConnection
    }

    /// An inbound 1:1 call from Alice to Bob, the local participant.
    private func makeInboundCall() throws -> Call {
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        return try Call(sharedCommunicationId: UUID().uuidString, sender: alice, recipients: [bob])
    }

    /// Registers Bob's peer connection for `call`, as `createPeerConnection` does when the call rings.
    private func addConnection(for call: Call, to session: RTCSession) async throws -> WebRTC.RTCPeerConnection {
        let peerConnection = try makePeerConnection()
        let identity = try await KeyManager().generateSenderIdentity(
            connectionId: call.sharedCommunicationId,
            secretName: "bob"
        )
        let (_, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        await session.connectionManager.addConnection(RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: peerConnection,
            delegateWrapper: RTCPeerConnectionDelegateWrapper(
                connectionId: call.sharedCommunicationId,
                logger: NeedleTailLogger("[LateRemoteDescriptionAfterTeardownTests]"),
                continuation: continuation
            ),
            sender: "bob",
            recipient: "alice",
            localKeys: identity.localKeys,
            symmetricKey: identity.symmetricKey,
            sessionIdentity: identity.sessionIdentity,
            call: call
        ))
        return peerConnection
    }

    /// Alice's offer: one audio m-line.
    private func makeRemoteOffer() async throws -> SessionDescription {
        let alice = try makePeerConnection()
        defer { alice.close() }
        _ = alice.addTransceiver(of: .audio)
        let offer = try await alice.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        return try SessionDescription(fromRTC: offer)
    }

    @Test("an offer applied after its call was hung up leaves no remote-description state for the next call")
    func lateOfferAfterHangupLeavesNoStateForNextCall() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: events)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        await session.setSessionParticipant(bob)

        let callA = try makeInboundCall()
        try await session.setupCallState(callA)
        let peerConnectionA = try await addConnection(for: callA, to: session)
        let offer = try await makeRemoteOffer()

        let hold = try HeldSetRemoteDescription(peerConnection: peerConnectionA)
        defer { hold.restore() }

        // Call A's offer lands in WebRTC; setRemote is still suspended when the hangup runs.
        let lateOffer = Task {
            try await session.handleOffer(call: callA, sdp: offer, answerDeviceId: "bob-device")
        }
        let applyError = await hold.waitUntilApplied()
        #expect(applyError == nil, "WebRTC did not apply the offer: \(String(describing: applyError))")
        try await session.endCall(callA)
        hold.release()

        // Call A is gone, so its offer is not answered.
        do {
            _ = try await lateOffer.value
            Issue.record("the offer of a hung-up call was answered")
        } catch RTCErrors.connectionNotFound {
        } catch {
            Issue.record("expected connectionNotFound, got \(error)")
        }

        #expect(await session.pcState == .none, "the late setRemote re-set the global pcState")
        #expect(await session.pcStateByConnectionId.isEmpty, "the late setRemote re-created call A's pcState")
        #expect(await session.inboundCandidateConsumers.isEmpty, "the late setRemote re-created call A's candidate buffer")

        // Call B rings; its first candidate arrives before its offer and must wait for it.
        let callB = try makeInboundCall()
        try await session.setupCallState(callB)
        _ = try await addConnection(for: callB, to: session)
        let earlyCandidate = IceCandidate(
            id: 1,
            sdp: "candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host",
            sdpMLineIndex: 0,
            sdpMid: "0"
        )
        await #expect(throws: Never.self, "call B's early candidate was applied before its remote description") {
            try await session.setRemote(candidate: earlyCandidate, call: callB)
        }

        await session.shutdown(with: nil)
    }

    /// The Android `setRemote` does not compile on macOS, so it is pinned by source: both platforms
    /// record a remote description only through the connection check, and a dropped offer is not answered.
    @Test("both setRemote variants record the remote description only through the connection check")
    func remoteDescriptionStateIsRecordedOnlyThroughConnectionCheck() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let exchange = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+Exchange.swift"),
            encoding: .utf8
        )
        for setRemote in ["setRemote(\n        sdp: RTCSessionDescription,", "setRemote(\n        sdp: WebRTC.RTCSessionDescription,"] {
            let body = try SourceContract.sourceBody(of: setRemote, in: exchange)
            #expect(body.contains("return await recordRemoteDescriptionApplied(on: connection, call: call)"))
        }
        #expect(exchange.components(separatedBy: "pcState = PeerConnectionState.setRemote").count - 1 == 1)
        #expect(exchange.components(separatedBy: "] = .setRemote").count - 1 == 1)
        let helper = try SourceContract.sourceBody(of: "recordRemoteDescriptionApplied", in: exchange)
        #expect(helper.contains("=== connection.peerConnection"))
        for handler in ["handleOffer", "handleRenegotiationOffer"] {
            let body = try SourceContract.sourceBody(of: handler, in: exchange)
            #expect(body.components(separatedBy: "guard remoteApplyResult == .applied else { throw RTCErrors.connectionNotFound }").count - 1 == 1)
        }
    }
}
#endif
