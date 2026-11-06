import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

/// `createOffer` and `createAnswer` poll for their peer connection to be ready before negotiating.
/// An offer whose connection is already registered must not pay a polling interval, and an answer
/// whose remote description never lands must give up within its documented ~10 s budget.
@Suite(.serialized)
struct OfferAnswerReadinessWaitTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func makeCall(sharedId: String) throws -> Call {
        let sender = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "alice-device")
        let recipient = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "bob-device")
        return try Call(sharedCommunicationId: sharedId, sender: sender, recipients: [recipient])
    }

    private func makeConnection(call: Call) async throws -> RTCConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        let keyManager = KeyManager()
        let localIdentity = try await keyManager.generateSenderIdentity(
            connectionId: call.sharedCommunicationId,
            secretName: "alice"
        )
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        _ = stream
        let delegateWrapper = RTCPeerConnectionDelegateWrapper(
            connectionId: call.sharedCommunicationId,
            logger: NeedleTailLogger("[OfferAnswerReadinessWaitTests]"),
            continuation: continuation
        )
        return RTCConnection(
            id: call.sharedCommunicationId,
            peerConnection: peerConnection,
            delegateWrapper: delegateWrapper,
            sender: "alice",
            recipient: "bob",
            localKeys: localIdentity.localKeys,
            symmetricKey: localIdentity.symmetricKey,
            sessionIdentity: localIdentity.sessionIdentity,
            call: call
        )
    }

    @Test("createOffer does not wait a polling interval when the connection already exists")
    func createOfferWithRegisteredConnectionDoesNotWaitAPollInterval() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        let call = try makeCall(sharedId: UUID().uuidString)
        _ = try await session.keyManager.generateSenderIdentity(connectionId: call.sharedCommunicationId, secretName: "alice")
        _ = try await session.pcKeyManager.generateSenderIdentity(connectionId: call.sharedCommunicationId, secretName: "alice")
        let connection = try await makeConnection(call: call)
        await session.connectionManager.addConnection(connection)

        var offered: Call?
        let elapsed = try await ContinuousClock().measure {
            offered = try await session.createOffer(call: call)
        }

        #expect(offered?.metadata != nil, "createOffer should return the call carrying the SDP offer")
        #expect(elapsed < .seconds(1), "createOffer took \(elapsed) with its connection already registered")

        connection.peerConnection.close()
        await session.shutdown(with: nil)
    }

    @Test("createAnswer gives up within ~10 s when the remote description never lands")
    func createAnswerGivesUpWithinBudgetWhenRemoteDescriptionNeverLands() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)
        let call = try makeCall(sharedId: UUID().uuidString)

        let finishedInTime = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                // No setRemote ever runs for this call, so the readiness wait can only expire.
                _ = try? await session.createAnswer(call: call)
                return !Task.isCancelled
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(finishedInTime, "createAnswer was still waiting for setRemote after 15 s")

        await session.shutdown(with: nil)
    }
}
#endif
