//
//  TaskProcessor.swift
//  pqs-rtc
//
//  Created by Cole M on 1/26/26.
//

import Foundation
import NeedleTailAsyncSequence
import Crypto
import DoubleRatchetKit
import BinaryCodable

struct Job: Sendable {
    let id: String
    let sequenceId: Int
    let task: TaskType
}

/// Deduplicates inbound ``PacketFlag.handshakeComplete`` SFU packets that are re-delivered with
/// the same ``RatchetMessage`` (e.g. SwiftSFU relay + client path). A second decrypt attempt
/// fails after the ratchet has already advanced, surfacing as a core-crypto error.
private struct ProcessedPostCipherHandshakeKey: Hashable, Sendable {
    let connectionId: String
    let ratchetMessage: RatchetMessage
}

actor TaskProcessor {
    
    let jobConsumer: NeedleTailAsyncConsumer<Job>
    let ratchetManager: DoubleRatchetStateManager<SHA256>
    let keyManager: KeyManager
    let rtcSession: RTCSession
    
    var sequenceId = 0
    var logger: NeedleTailLogger
    var isRunning = false

    /// Job currently inside ``process(_:)``. It has been popped from the deque but is still in
    /// `jobs` (removed only on completion), so cache reloads must not re-enqueue it — a second
    /// pass over the same StreamTask advances the ratchet twice and fails decrypt.
    private var inFlightJobId: String?

    // MARK: - Outbound send lane
    //
    // Transport delivery is decoupled from the serial crypto pipeline. `handleWriteMessage`
    // encrypts (ratchet order must stay serial) and then enqueues the packet here; a dedicated
    // drain task performs the actual `sendEncryptedPacket` network I/O. Without this, a single
    // send blocked on a congested uplink (SFU websocket backpressure / registration gate)
    // froze the whole pipeline: inbound `.answer`/`.candidate` decrypts queued behind it for
    // 60+ seconds, the remote SDP was applied a minute late, and the ICE fallback tore down an
    // otherwise healthy setup.

    /// One encrypted packet awaiting transport delivery, in encrypt order.
    private struct OutboundSend {
        let id = UUID()
        let packet: RatchetMessagePacket
        let task: WriteTask
    }

    private var outboundSends: [OutboundSend] = []
    private var outboundSenderTask: Task<Void, Never>?
    /// Terminal: set when this crypto-stack generation is retired; the lane never restarts.
    private var isOutboundLaneShutdown = false
    
    /// Ratchet messages already successfully applied for `.handshakeComplete` (per connection).
    private var processedPostCipherHandshakes: Set<ProcessedPostCipherHandshakeKey> = []
    
    private let executor: RatchetExecutor
    
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    
    public init(
        executor: RatchetExecutor,
        keyManager: KeyManager,
        logger: NeedleTailLogger,
        rtcSession: RTCSession,
        ratchetManager: DoubleRatchetStateManager<SHA256>
    ) {
        self.executor = executor
        self.keyManager = keyManager
        self.logger = logger
        self.rtcSession = rtcSession
        self.ratchetManager = ratchetManager
        self.jobConsumer = NeedleTailAsyncConsumer<Job>(logger: logger)
    }

    // MARK: - Atomic sequence

    func incrementId() -> Int {
        sequenceId += 1
        return sequenceId
    }
    
    enum Errors: Error {
        case cacheNotFound, invalidType, invalidSender
    }
    
    var jobs: [Job] = []
    
    func createJob(_ job: Job) {
        jobs.append(job)
    }
    
    func removeJob(id: String) {
        jobs.removeAll(where: { $0.id == id })
    }

    func removeJobs(forConnectionId connectionId: String) async {
        let normalized = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalized.isEmpty else { return }

        let beforeCached = jobs.count
        jobs.removeAll { job in
            job.referencesConnectionId(normalized)
        }
        let removedCached = beforeCached - jobs.count
        let removedQueued = await jobConsumer.removeQueuedJobs(forConnectionId: normalized)

        processedPostCipherHandshakes = Set(
            processedPostCipherHandshakes.filter { $0.connectionId != normalized }
        )

        let beforeSends = outboundSends.count
        outboundSends.removeAll { $0.task.referencesConnectionId(normalized) }
        let removedSends = beforeSends - outboundSends.count
        if removedSends > 0 {
            // The in-flight send may belong to this (now torn down) connection and could be
            // parked on a dead transport gate forever, holding the lane hostage. Cancel it;
            // the drain task's defer restarts a fresh lane for any surviving sends.
            outboundSenderTask?.cancel()
        }

        if removedCached > 0 || removedQueued > 0 || removedSends > 0 {
            logger.log(
                level: .debug,
                message: "Dropped stale task-processor jobs for connectionId=\(normalized) cached=\(removedCached) queued=\(removedQueued) outboundSends=\(removedSends)"
            )
        }
    }

    /// Terminally shuts down the outbound send lane. Called when this crypto-stack generation
    /// is retired; queued sends are stale by definition and the lane never restarts.
    func shutdownOutboundLane() {
        isOutboundLaneShutdown = true
        outboundSends.removeAll()
        outboundSenderTask?.cancel()
    }

    // MARK: - Public API

    public func feedTask(task: EncryptableTask) async throws {

        let seq = incrementId()
        let job = Job(
            id: UUID().uuidString,
            sequenceId: seq,
            task: task.task)
        
        createJob(job)

        // Insert directly into the consumer deque (sequence-ordered, id-deduped) and kick the
        // processor. Jobs fed while the loop is mid-run must not sit only in `jobs` until a
        // drain-reload: that stranded the inbound SFU `.answer` while later `.candidate`s ran.
        // Do not spin-wait for this job here: waiting on the TaskProcessor actor while a peer
        // loop is mid-pause/drain starves inbound SFU handling ("giving up wait after 201 yields").
        try await loadTasks(job)
    }

    public func loadTasks(_ job: Job? = nil) async throws {
        
        if let job {
            try await jobConsumer.loadAndOrganizeTasks(job)
        } else {
            for job in jobs where job.id != inFlightJobId {
                try await jobConsumer.loadAndOrganizeTasks(job)
            }
        }
        try await startProcessingIfNeeded()
    }

    // MARK: - Running Lock

    private func tryStart() -> Bool {
        if isRunning { return false }
        isRunning = true
        return true
    }

    private func stop() {
        isRunning = false
    }

    // MARK: - Startup

    private func startProcessingIfNeeded() async throws {
        guard tryStart() else { return }
        
        try await Task {
            defer {
                stop()
            }
            do {
                try await self.processingLoop()
            } catch {
                self.logger.log(level: .error, message: "Processor crashed: \(error)")
                throw error
            }
        }.value

        if !jobs.isEmpty {
            try await startProcessingIfNeeded()
        }
    }
    // MARK: - Core loop

    private static let maxPausedRetries = 8
    /// Essential `.offer`/`.answer` survive brief SFU `channel_inactive` / writer recycle.
    /// Writer-not-ready uses the same bound; transport-down retries are offer/answer only.
    private static let maxOutboundTransportRetries = 24
    private static let pausedRetryIntervalNs: UInt64 = 250_000_000 // 250ms

    /// Whether an outbound send failure should stay queued for another transport attempt.
    static func shouldRetryOutboundTransportSend(
        flag: PacketFlag,
        isWriterNotReady: Bool,
        isTransientTransportFailure: Bool,
        attempt: Int,
        maxAttempts: Int = maxOutboundTransportRetries
    ) -> Bool {
        guard attempt < maxAttempts else { return false }
        if isWriterNotReady { return true }
        // Renegotiation answers encrypted just as SFU recycled were dropped after one
        // failure — SFU never activated forwarding (one-way / missing remote video).
        if (flag == .offer || flag == .answer), isTransientTransportFailure {
            return true
        }
        return false
    }

    private func processingLoop() async throws {

        if await jobConsumer.deque.isEmpty {
            try await loadFromCache()
        }

        var consecutivePauses = 0

        func startLoop() async throws {

            if await jobConsumer.deque.isEmpty {
                if jobs.isEmpty {
                    await jobConsumer.gracefulShutdown()
                    return
                }
                try await loadFromCache()
            }

            for try await result in NeedleTailAsyncSequence(consumer: jobConsumer) {
                switch result {
                case let .success(job):
                    do {
                        
                        inFlightJobId = job.id
                        let outcome = try await process(job)
                        inFlightJobId = nil

                        if outcome == .paused {
                            consecutivePauses += 1
                            if consecutivePauses > Self.maxPausedRetries {
                                logger.log(level: .warning, message: "Paused job exceeded \(Self.maxPausedRetries) retries, dropping: \(job.id)")
                                removeJob(id: job.id)
                                consecutivePauses = 0
                            } else {
                                await jobConsumer.gracefulShutdown()
                                try? await Task.sleep(nanoseconds: Self.pausedRetryIntervalNs)
                                if Task.isCancelled { return }
                                try await loadFromCache()
                                break
                            }
                        } else {
                            consecutivePauses = 0
                        }
                        if await jobConsumer.deque.isEmpty {
                            // Mid-flight `feedTask` can land jobs in `jobs` after the deque drained.
                            // Returning here strands them until a later feed (e.g. inbound SFU
                            // `.answer` stranded while `.candidate` decrypts out of order).
                            if !jobs.isEmpty {
                                break
                            }
                            await jobConsumer.gracefulShutdown()
                            return
                        }
                    } catch {
                        inFlightJobId = nil
                        await jobConsumer.gracefulShutdown()
                        throw error
                    }
                case .consumed:
                    break
                }
            }
            try await startLoop()
        }
        try await startLoop()
    }

    // MARK: - Cache loading

    private func loadFromCache() async throws {
        for job in jobs where job.id != inFlightJobId {
            try await jobConsumer.loadAndOrganizeTasks(job)
        }
    }

    // MARK: - Job execution

    private func process(_ job: Job) async throws -> JobProcessingOutcome {

        do {
            try await performRatchet(task: job.task)
            removeJob(id: job.id)
            return .processed

        } catch JobProcessorErrors.missingIdentity {
            // Don't remove the job - keep it in cache to retry when identity is created
            logger.log(level: .debug, message: "Job paused - identity not yet created, will retry: \(job.id)")
            return .paused
        } catch let error as RTCErrors {
            switch error {
            case .invalidConfiguration(let message):
                let lower = message.lowercased()
                if lower.contains("missing connection identity") || lower.contains("missing local connection identity") {
                    // This is expected when late jobs from a previous call race teardown.
                    removeJob(id: job.id)
                    logger.log(level: .debug, message: "Dropping stale job with missing identity: \(job.id) (\(message))")
                    return .deleted
                }
            default:
                break
            }
            removeJob(id: job.id)
            logger.log(level: .error, message: "Job error: \(error)")
            await escalateTerminalFailureIfEssential(job: job, error: error)
            return .failed
        } catch let error as RatchetError {
            // Ratchet state is out of sync - this can happen if messages arrive out of order
            // or if recipient initialization happened with the wrong header
            // Don't remove the job - keep it in cache to retry after identity is properly initialized
            logger.log(level: .error, message: "❌ JOB RATCHET ERROR: \(error) - job will be retried: \(job.id)")
            return .paused
        } catch {
            if isWriterNotReadyError(error) {
                logger.log(level: .debug, message: "Job paused - transport writer not ready, will retry: \(job.id)")
                return .paused
            }
            removeJob(id: job.id)
            logger.log(level: .error, message: "Job error: \(error)")
            await escalateTerminalFailureIfEssential(job: job, error: error)
            // Keep the job in cache for now (retry semantics are handled elsewhere / future improvements).
            return .failed
        }
    }

    /// Essential outbound signaling (`.offer`/`.answer`) that fails terminally must fail the
    /// call loudly: the job is dropped, so the SFU/peer waits forever for an SDP that will
    /// never arrive and the call sits in "Connecting" with nothing but a log line. RTCSession
    /// decides whether the call is still establishing (stale jobs racing teardown are ignored).
    private func escalateTerminalFailureIfEssential(job: Job, error: Error) async {
        guard case let .writeMessage(task) = job.task else { return }
        await escalateSendFailureIfEssential(task: task, error: error)
    }

    private func escalateSendFailureIfEssential(task: WriteTask, error: Error) async {
        guard task.flag == .offer || task.flag == .answer else { return }
        await rtcSession.handleTerminalSignalingJobFailure(task: task, error: error)
    }

    private func isWriterNotReadyError(_ error: Error) -> Bool {
        if let description = (error as? LocalizedError)?.errorDescription,
           description.localizedCaseInsensitiveContains("writer not set") {
            return true
        }
        return String(describing: error).localizedCaseInsensitiveContains("writernotset")
    }

    /// Socket recycle / channel_inactive / non-viable transport — recoverable while the call lives.
    /// Static so tests can pin the production signatures (e.g. NIO "I/O on closed channel").
    static func isTransientTransportSendError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let text: String
        if let localized = (error as? LocalizedError)?.errorDescription {
            text = localized
        } else {
            text = String(describing: error)
        }
        let lowered = text.lowercased()
        return lowered.contains("writernotset")
            || lowered.contains("writer not set")
            || lowered.contains("connectionisnonviable")
            || lowered.contains("connection is non-viable")
            || lowered.contains("connection is nonviable")
            || lowered.contains("channel inactive")
            || lowered.contains("channel_inactive")
            // NIO ChannelError.ioOnClosedChannel — the exact error that dropped the
            // production renegotiation answer during an SFU socket recycle.
            || lowered.contains("closed channel")
            || lowered.contains("ioonclosedchannel")
            // NIOAsyncWriterError after the writer finished during teardown/recycle.
            || lowered.contains("alreadyfinished")
            || lowered.contains("already finished")
            || lowered.contains("not connected")
            || lowered.contains("socket is not connected")
            || lowered.contains("broken pipe")
            || lowered.contains("connection reset")
    }

    // MARK: - Job Processing Outcomes

    enum JobProcessingOutcome: Sendable, Equatable {
        /// Job completed successfully and was removed from cache.
        case processed
        /// Job was removed from cache without running (e.g., invalid/missing identity).
        case deleted
        /// Processing should pause (e.g., session non-viable); job remains in cache to be reloaded later.
        case paused
        /// Job failed but was not deleted (best-effort retry semantics).
        case failed
    }

    // MARK: - Errors

    enum JobProcessorErrors: Error, LocalizedError {
        case missingIdentity

        public var errorDescription: String? {
            "Job references a missing session identity"
        }

        public var recoverySuggestion: String? {
            "Ensure the session identity exists before processing the job"
        }
    }
    
    func performRatchet(task: TaskType) async throws {
        await ratchetManager.setDelegate(keyManager)
        switch task {
        case let .writeMessage(outboundTask):
            try await handleWriteMessage(outboundTask: outboundTask)
        case let .streamMessage(inboundTask):
            try await handleStreamMessage(inboundTask: inboundTask)
        }
    }
    
    private func handleWriteMessage(outboundTask: WriteTask) async throws {
        let connectionIdentity = try await keyManager.fetchCallKeyBundle()
        let identityLookupId = outboundTask.call.resolvedChannelWireId == nil
            ? outboundTask.roomId.normalizedConnectionId
            : outboundTask.call.sharedCommunicationId.normalizedConnectionId
        
        // In PQSRTC, we fetch by normalized connectionId (UUID, no "#"); wire format uses "#" for IRC.
        let connectionSessionIdentity = try await keyManager.fetchConnectionIdentity(connection: identityLookupId)
        
        let identity = connectionSessionIdentity.sessionIdentity
        
        // Get remote props for senderInitialization (unwrap remote identity with the key it was created with)
        guard let remoteProps = await identity.props(symmetricKey: connectionSessionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote props not found for roomId=\(outboundTask.roomId)")
        }

        // Diagnostic (opt-in via SFU_DEBUG_CRYPTO_WIRING): prove which identities this
        // frame is encrypted with (public-key digest prefixes only; no key material).
        // Compare `remotePropsFp` with the SFU's logged room identity fingerprint, and
        // `localPropsFp` with the fingerprint the SFU stored at negotiation, to pin any
        // decrypt mismatch.
        if KeyFingerprint.isEnabled {
            let localPropsFp = await KeyFingerprint.localIdentity(connectionIdentity)
            logger.log(
                level: .info,
                message: "SFU encrypt outbound flag=\(outboundTask.flag) room=\(identityLookupId) sessionId=\(identity.id.uuidString) remotePropsFp=\(KeyFingerprint.props(remoteProps)) localPropsFp=\(localPropsFp)")
        }

        // Call senderInitialization before encrypt
        try await ratchetManager.senderInitialization(
            sessionIdentity: identity,
            sessionSymmetricKey: connectionIdentity.symmetricKey,
            remoteKeys: RemoteKeys(
                longTerm: CurvePublicKey(remoteProps.longTermPublicKey),
                oneTime: remoteProps.oneTimePublicKey,
                mlKEM: remoteProps.mlKEMPublicKey),
            localKeys: connectionIdentity.localKeys)
        
        let message = try await ratchetManager.ratchetEncrypt(plainText: outboundTask.data, sessionId: identity.id)
        
        logger.log(level: .info, message: "Encrypted Message", metadata: ["roomId":"\(outboundTask.roomId)", "flag":"\(outboundTask.flag)"])
        
        let encrypted = RatchetMessagePacket(
            sfuIdentity: outboundTask.roomId,
            header: message.header,
            ratchetMessage: message,
            flag: outboundTask.flag)
        
        // Hand off to the outbound send lane; the crypto pipeline must never await network I/O
        // (a stalled transport send would block every inbound decrypt queued behind it).
        enqueueOutboundSend(OutboundSend(packet: encrypted, task: outboundTask))
    }

    // MARK: - Outbound lane drain

    private func enqueueOutboundSend(_ send: OutboundSend) {
        guard !isOutboundLaneShutdown else {
            logger.log(level: .debug, message: "Dropping outbound send after lane shutdown flag=\(send.task.flag) room=\(send.task.roomId)")
            return
        }
        outboundSends.append(send)
        startOutboundSenderIfNeeded()
    }

    private func startOutboundSenderIfNeeded() {
        guard outboundSenderTask == nil, !isOutboundLaneShutdown else { return }
        outboundSenderTask = Task { await self.drainOutboundSends() }
    }

    private func drainOutboundSends() async {
        defer {
            outboundSenderTask = nil
            // A purge-cancel leaves surviving sends for other connections queued; restart for them.
            if !outboundSends.isEmpty, !isOutboundLaneShutdown {
                startOutboundSenderIfNeeded()
            }
        }

        var retryingSendId: UUID?
        var transportRetries = 0

        while !Task.isCancelled {
            guard let send = outboundSends.first else { return }
            if send.id != retryingSendId {
                retryingSendId = send.id
                transportRetries = 0
            }
            do {
                try await rtcSession.sendEncryptedPacket(packet: send.packet, call: send.task.call)
                removeOutboundSend(id: send.id)
            } catch {
                // Lane cancelled mid-send (teardown/purge): remaining sends are stale, no escalation.
                if Task.isCancelled { return }
                let writerNotReady = isWriterNotReadyError(error)
                let transientTransport = Self.isTransientTransportSendError(error)
                if Self.shouldRetryOutboundTransportSend(
                    flag: send.task.flag,
                    isWriterNotReady: writerNotReady,
                    isTransientTransportFailure: transientTransport,
                    attempt: transportRetries
                ) {
                    transportRetries += 1
                    logger.log(
                        level: .debug,
                        message: "Outbound send waiting for transport (attempt \(transportRetries)) flag=\(send.task.flag) writerNotReady=\(writerNotReady) transient=\(transientTransport)")
                    try? await Task.sleep(nanoseconds: Self.pausedRetryIntervalNs)
                    continue
                }
                removeOutboundSend(id: send.id)
                logger.log(level: .error, message: "Outbound send failed flag=\(send.task.flag) room=\(send.task.roomId): \(error)")
                await escalateSendFailureIfEssential(task: send.task, error: error)
            }
        }
    }

    private func removeOutboundSend(id: UUID) {
        outboundSends.removeAll { $0.id == id }
    }
    
    private func handleStreamMessage(inboundTask: StreamTask) async throws {
        let packet = inboundTask.packet
        let roomId = packet.sfuIdentity
        let identityLookupId = inboundTask.call.resolvedChannelWireId == nil
            ? roomId.normalizedConnectionId
            : inboundTask.call.sharedCommunicationId.normalizedConnectionId
        
        if packet.flag == .handshakeComplete {
            let dedupKey = ProcessedPostCipherHandshakeKey(
                connectionId: identityLookupId,
                ratchetMessage: packet.ratchetMessage)
            if processedPostCipherHandshakes.contains(dedupKey) {
                logger.log(
                    level: .debug,
                    message: "Skipping duplicate post-cipher handshakeComplete (already applied). room=\(roomId)"
                )
                return
            }
        }
        
        logger.log(level: .info, message: "PQS RTC handling encrypted packet", metadata: ["roomId":"\(roomId)", "flag":"\(packet.flag)"])

        // Fetch by normalized ID (packet.sfuIdentity may have "#" from IRC).
        let connectionSessionIdentity = try await keyManager.fetchConnectionIdentity(connection: identityLookupId)
        let connectionIdentity = try await keyManager.fetchCallKeyBundle()
        
        try await ratchetManager.recipientInitialization(
            sessionIdentity: connectionSessionIdentity.sessionIdentity,
            sessionSymmetricKey: connectionIdentity.symmetricKey,
            header: inboundTask.packet.ratchetMessage.header,
            localKeys: connectionIdentity.localKeys)
        
        let identity = connectionSessionIdentity.sessionIdentity
        
        let plaintext = try await ratchetManager.ratchetDecrypt(packet.ratchetMessage, sessionId: identity.id)
        
        // Delegate to RTCSession to handle the decrypted message
        try await rtcSession.handleDecryptedPacket(
            plaintext: plaintext,
            packet: packet,
            call: inboundTask.call)
        
        if packet.flag == .handshakeComplete {
            processedPostCipherHandshakes.insert(
                ProcessedPostCipherHandshakeKey(
                    connectionId: identityLookupId,
                    ratchetMessage: packet.ratchetMessage))
        }
    }
}

private extension Job {
    func referencesConnectionId(_ normalizedConnectionId: String) -> Bool {
        switch task {
        case .writeMessage(let outboundTask):
            return outboundTask.referencesConnectionId(normalizedConnectionId)
        case .streamMessage(let inboundTask):
            let packetRoom = inboundTask.packet.sfuIdentity.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
            let callId = inboundTask.call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
            return packetRoom == normalizedConnectionId || callId == normalizedConnectionId
        }
    }
}

extension WriteTask {
    func referencesConnectionId(_ normalizedConnectionId: String) -> Bool {
        let room = roomId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let callId = call.sharedCommunicationId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        return room == normalizedConnectionId || callId == normalizedConnectionId
    }
}


/// An enumeration representing the type of task, which can be either an inbound or outbound message.
///
/// This enum provides type safety for distinguishing between incoming and outgoing
/// message processing tasks in the job queue system.
enum TaskType: Codable & Sendable {
    /// A task for processing an incoming message from a sender.
    case streamMessage(StreamTask)
    /// A task for sending an outgoing message to a recipient.
    case writeMessage(WriteTask)
}

struct WriteTask: Codable, Sendable {
    let data: Data
    let roomId: String
    let flag: PacketFlag
    let call: Call
}

struct StreamTask: Codable & Sendable {
    let senderSecretName: String
    let senderDeviceId: UUID?
    let packet: RatchetMessagePacket
    let call: Call
}


/// A struct representing an encryptable task with associated priority and scheduling information.
///
/// This struct wraps a task with additional metadata for job queue management,
/// including priority levels and scheduling information for optimal processing.
struct EncryptableTask: Codable & Sendable {
    /// The task type, which can be an inbound or outbound message.
    public let task: TaskType

    /// The priority of the task for queue ordering and resource allocation.
    public let priority: Priority

    /// The date and time when the task is scheduled for execution.
    public let scheduledAt: Date

    /// Initializes a new instance of `EncryptableTask`.
    /// - Parameters:
    ///   - task: The task type (inbound or outbound message).
    ///   - priority: The priority of the task (default is `.standard`).
    ///   - scheduledAt: The date and time when the task is scheduled (default is the current date).
    public init(
        task: TaskType,
        priority: Priority = .standard,
        scheduledAt: Date = Date()
    ) {
        self.task = task
        self.priority = priority
        self.scheduledAt = scheduledAt
    }
}


extension NeedleTailAsyncConsumer {

    func loadAndOrganizeTasks(_ job: Job) async throws {

        guard let typedJob = job as? T else {
            throw TaskProcessor.Errors.invalidType
        }

        // A job can reach here twice: fed directly by `feedTask` AND reloaded from the `jobs`
        // cache by `loadFromCache` after a pause/drain. Processing the same StreamTask twice
        // advances the ratchet twice and the second decrypt fails with a core-crypto error,
        // so dedup by job id before inserting.
        if deque.contains(where: { ($0.item as? Job)?.id == job.id }) {
            return
        }

        let taskJob = TaskJob(item: typedJob, priority: .standard)
        
        // Always use sequence-based insertion to ensure FIFO ordering and prevent race conditions
        await insertSequence(
            taskJob,
            sequenceId: job.sequenceId)
    }
    
    private func insertSequence(_ taskJob: TaskJob<T>, sequenceId: Int) async {
        // Since NeedleTailAsyncConsumer is an actor, all operations are atomic
        // Find the index where the new job should be inserted
        // See post-quantum-solace `NeedleTailAsyncConsumer+Extension.insertSequence`: `await` in the
        // predicate allows actor reentrancy; the deque may shrink before insert — clamp the offset.
        let rawIndex = await deque.firstAsyncIndex(where: {
            guard let job = $0.item as? Job else {
                return false
            }
            let currentJobSequenceId = job.sequenceId
            return currentJobSequenceId >= sequenceId // Find the first job with a sequence ID greater than or equal to the new job
        }) ?? deque.count // If no such index is found, use the end of the deque

        let insertIndex = min(max(0, rawIndex), deque.count)
        deque.insert(taskJob, at: insertIndex)
    }

    func gracefulShutdown() async {
        // Clear the deque to stop processing
        deque.removeAll()
    }

    func removeQueuedJobs(forConnectionId connectionId: String) async -> Int where T == Job {
        let before = deque.count
        deque.removeAll { taskJob in
            taskJob.item.referencesConnectionId(connectionId)
        }
        return before - deque.count
    }
}

import DequeModule
public extension Deque {
    func firstAsyncIndex(where predicate: @Sendable (Element) async -> Bool) async -> Int? {
        for (index, element) in enumerated() {
            if await predicate(element) {
                return index
            }
        }
        return nil
    }
}
