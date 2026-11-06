import Foundation
import Testing

@testable import PQSRTC

/// Holds a `CallStateMachine` busy so every hop onto it queues until `open()`.
private final class CallStateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private let released = DispatchSemaphore(value: 0)

    var isOccupied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return occupied
    }

    func occupy() {
        lock.lock()
        occupied = true
        lock.unlock()
        released.wait()
    }

    func open() {
        released.signal()
    }
}

extension CallStateMachine {
    fileprivate func occupyIsolation(_ gate: CallStateGate) {
        gate.occupy()
    }
}

@Suite(.serialized)
struct OverlappingShutdownTeardownTests {
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

    /// Enqueues both shutdowns on the session actor in order, so each runs up to its
    /// first hop onto `callState` before the caller's next session hop.
    private func startTwoShutdowns(
        on session: isolated RTCSession,
        call: Call
    ) -> [Task<Void, Never>] {
        [
            Task { _ = session.stateTaskGeneration; await session.shutdown(with: call) },
            Task { _ = session.stateTaskGeneration; await session.shutdown(with: call) },
        ]
    }

    @Test("overlapping shutdowns run one teardown body; the second waits for it")
    func overlappingShutdownsRunOneTeardown() async throws {
        let session = await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: Transport()
        )
        let call = try Call(
            sharedCommunicationId: UUID().uuidString,
            sender: Call.Participant(secretName: "sender", nickname: "Sender", deviceId: "s"),
            recipients: [Call.Participant(secretName: "recipient", nickname: "Recipient", deviceId: "r")]
        )
        let teardownsBefore = await session.stateTaskGeneration

        // Park both shutdowns at the live-attempt check (`await callState.currentCall`),
        // the suspension point between the in-progress check and the claim.
        let gate = CallStateGate()
        let callState = await session.callState
        let occupier = Task.detached { await callState.occupyIsolation(gate) }
        defer { gate.open() }
        while !gate.isOccupied {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let shutdowns = await startTwoShutdowns(on: session, call: call)
        // Runs after both shutdown jobs reached their callState hop.
        _ = await session.stateTaskGeneration

        gate.open()
        await occupier.value
        for shutdown in shutdowns {
            await shutdown.value
        }

        let teardownBodies = await session.stateTaskGeneration &- teardownsBefore
        #expect(teardownBodies == 1, "two overlapping shutdowns ran \(teardownBodies) teardown bodies")
        #expect(await session.isCallTeardownInProgress == false)
    }
}
