import Foundation
import Testing

@testable import PQSRTC

/// Receiver-cryptor and network-quality events are deduped per participant / connection.
/// That dedupe state belongs to one call: the next call with the same peer, or on the same
/// reused room id, must report from scratch.
@Suite(.serialized)
struct NextCallEventDedupeTests {
    actor Transport: RTCTransportEvents {
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

    actor E2EELog {
        private(set) var events: [E2EEStateEvent] = []
        func append(_ event: E2EEStateEvent) { events.append(event) }
        func contains(fence: String) -> Bool { events.contains { $0.connectionId == fence } }
        var receiverEvents: [String] {
            events.filter { $0.mediaKind != "fence" }.map { "\($0.participantId):\($0.kind.rawValue)" }
        }
    }

    @Test
    func nextCallWithSamePeerReportsReceiverCryptorStateFromScratch() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: Transport())
        let log = E2EELog()
        let stream = await session.e2eeStateStream()
        let consumer = Task { for await event in stream { await log.append(event) } }
        defer { consumer.cancel() }
        try await fence(session, log)

        let conversation = UUID().uuidString
        let firstCall = try oneToOneCall(conversation)
        let nextCall = try oneToOneCall(conversation)

        // First call ends while both remote cryptors are failing.
        try await session.setupCallState(firstCall)
        await session.handleReceiverCryptorStateDescription(participantId: "bob", stateDescription: "missingKey", mediaKind: "video")
        await session.handleReceiverCryptorStateDescription(participantId: "carol", stateDescription: "decryptionFailed", mediaKind: "video")
        await session.shutdown(with: firstCall)
        try await fence(session, log)
        let firstCallEvents = await log.receiverEvents
        #expect(firstCallEvents == ["bob:receiverMissingKey", "carol:receiverDecryptionFailed"])

        // Next call with the same peers: bob has no key yet, carol starts healthy.
        try await session.setupCallState(nextCall)
        await session.handleReceiverCryptorStateDescription(participantId: "bob", stateDescription: "missingKey", mediaKind: "video")
        await session.handleReceiverCryptorStateDescription(participantId: "carol", stateDescription: "ok", mediaKind: "video")
        try await fence(session, log)

        let nextCallEvents = Array(await log.receiverEvents.dropFirst(firstCallEvents.count))
        #expect(nextCallEvents == ["bob:receiverMissingKey"])
        await session.shutdown(with: nextCall)
    }

    @Test
    func nextCallOnSameRoomReportsItsFirstNetworkQuality() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: Transport())
        var updates = await session.createNetworkQualityStream().makeAsyncIterator()
        let conversation = UUID().uuidString
        let firstCall = try oneToOneCall(conversation)
        let nextCall = try oneToOneCall(conversation)

        try await session.setupCallState(firstCall)
        await emit(session, connectionId: conversation, quality: .good, atSeconds: 10)
        #expect(await updates.next()?.connectionId == conversation)
        await session.shutdown(with: firstCall)

        try await session.setupCallState(nextCall)
        await emit(session, connectionId: conversation, quality: .good, atSeconds: 20)
        // A different connection's update fences the stream: if the room's update was
        // suppressed, this arrives first.
        await emit(session, connectionId: "fence", quality: .poor, atSeconds: 21)
        let first = await updates.next()
        #expect(first?.connectionId == conversation)
        #expect(first?.quality == .good)
        await session.shutdown(with: nextCall)
    }

    private func oneToOneCall(_ conversation: String) throws -> Call {
        let alice = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: "a")
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: "b")
        return try Call(sharedCommunicationId: conversation, sender: alice, recipients: [bob])
    }

    private func emit(_ session: RTCSession, connectionId: String, quality: RTCNetworkQuality, atSeconds: UInt64) async {
        await session.emitNetworkQualityUpdateIfNeeded(
            connectionId: connectionId,
            quality: quality,
            availableOutgoingBitrateBps: nil,
            rttMs: nil,
            appliedVideoMaxBitrateBps: nil,
            appliedVideoMaxFramerate: nil,
            nowUptimeNs: atSeconds * 1_000_000_000)
    }

    /// `e2eeStateStream()` registers through a Task, so delivery is confirmed with a marker.
    /// Events arrive in order, so once the marker is logged every earlier event is logged too.
    private func fence(_ session: RTCSession, _ log: E2EELog) async throws {
        let marker = "fence-\(UUID().uuidString)"
        for _ in 0..<400 {
            await session.notifyE2EEState(
                E2EEStateEvent(connectionId: marker, kind: .senderCryptorReady, mediaKind: "fence"))
            try await Task.sleep(for: .milliseconds(5))
            if await log.contains(fence: marker) { return }
        }
        Issue.record("E2EE state stream never delivered the fence")
    }
}
