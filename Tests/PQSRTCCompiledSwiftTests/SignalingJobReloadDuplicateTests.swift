import Foundation
import Testing
import DoubleRatchetKit
import Dispatch
#if canImport(WebRTC) && !os(Android)

@testable import PQSRTC

/// `resumePausedSignalingJobs()` reloads every cached job into the consumer. A job the loop
/// has already popped is no longer in the deque, so the reload puts it back and the loop
/// encrypts and sends it a second time.
@Suite(.serialized)
struct SignalingJobReloadDuplicateTests {
    actor Transport: RTCTransportEvents {
        private(set) var negotiated: [(call: Call, sfuRecipientId: String)] = []
        private(set) var sfuFlags: [PacketFlag] = []

        func sendCiphertext(recipient: String, connectionId: String, ciphertext: Data, call: Call) async throws {}
        func sendSfuMessage(_ packet: RatchetMessagePacket, call: Call) async throws {
            sfuFlags.append(packet.flag)
        }
        func sendStartCall(_ call: Call) async throws {}
        func sendCallAnswered(_ call: Call) async throws {}
        func sendCallAnsweredAuxDevice(_ call: Call) async throws {}
        func sendOneToOneMessage(_ packet: RatchetMessagePacket, recipient: Call.Participant) async throws {}
        func didEnd(call: Call, endState: CallStateMachine.EndState) async throws {}
        func negotiateGroupIdentity(call: Call, sfuRecipientId: String) async throws {
            negotiated.append((call: call, sfuRecipientId: sfuRecipientId))
        }
        func requestInitializeGroupCallRecipient(call: Call, sfuRecipientId: String) async throws {}

        func count(_ flag: PacketFlag) -> Int { sfuFlags.filter { $0 == flag }.count }
    }

    /// Holds the loop once on the first popped job that carries `marker`.
    actor PopGate {
        private var used = false
        private(set) var isHolding = false
        private var release: CheckedContinuation<Void, Never>?

        func hold(_ job: Job, marker: Data) async {
            guard !used, case .writeMessage(let write) = job.task, write.data == marker else { return }
            used = true
            isHolding = true
            await withCheckedContinuation { release = $0 }
            isHolding = false
        }

        func open() {
            release?.resume()
            release = nil
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
    func resumeWhileLoopHoldsPoppedJob_encryptsAndSendsItOnce() async throws {
        let transport = Transport()
        let session = await RTCSession(iceServers: ["stun:stun.l.google.com:19302"], username: "u", password: "p", delegate: transport)

        let sfuRecipientId = "sfu"
        let local = try Call.Participant(secretName: "alice", nickname: "Alice", deviceId: UUID().uuidString)
        let bob = try Call.Participant(secretName: "bob", nickname: "Bob", deviceId: UUID().uuidString)

        try await session.join(sender: local, participants: [bob], sfuRecipientId: sfuRecipientId, supportsVideo: false)
        let negotiated = await waitUntil(timeoutSeconds: 5.0) { await transport.negotiated.isEmpty == false }
        try #require(negotiated)
        let negotiatedCall = await transport.negotiated.last!.call

        let sfuKeyStore = KeyManager()
        let sfuLocalIdentity = try await sfuKeyStore.generateSenderIdentity(
            connectionId: sfuRecipientId,
            secretName: sfuRecipientId
        )
        let sfuProps = try #require(await sfuLocalIdentity.sessionIdentity.props(symmetricKey: sfuLocalIdentity.symmetricKey))
        var call = negotiatedCall
        call.signalingIdentityProps = sfuProps
        try await session.createSFUIdentity(sfuRecipientId: sfuRecipientId, call: call)

        let processor = await session.taskProcessor
        let gate = PopGate()
        let marker = Data("reload-duplicate-offer".utf8)
        await processor.setWillProcessJobForTesting({ job in await gate.hold(job, marker: marker) })

        func write(_ data: Data, _ flag: PacketFlag) -> EncryptableTask {
            EncryptableTask(task: .writeMessage(WriteTask(
                data: data,
                roomId: call.sharedCommunicationId,
                flag: flag,
                call: call)))
        }

        // The loop pops the offer job and is still on its way to running it.
        let offer = write(marker, .offer)
        let feeding = Task { try await processor.feedTask(task: offer) }
        let popped = await waitUntil(timeoutSeconds: 5.0) { await gate.isHolding }
        try #require(popped)

        // SFU writer reconnected: the host resumes paused signalling while the loop is busy.
        try await session.resumePausedSignalingJobs()
        await gate.open()
        try await feeding.value

        // The send lane is FIFO: once a later packet is on the wire, every earlier send is too.
        try await processor.feedTask(task: write(Data("barrier".utf8), .candidate))
        let drained = await waitUntil(timeoutSeconds: 5.0) { await transport.count(.candidate) == 1 }
        try #require(drained)

        let offers = await transport.count(.offer)
        #expect(offers == 1, "The reload re-inserted the popped offer job and it was encrypted and sent \(offers) times")
        #expect(await processor.jobs.isEmpty)

        await processor.setWillProcessJobForTesting(nil)
        await session.shutdown(with: nil)
    }
}
#endif
