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

actor TaskProcessor {
    
    let jobConsumer: NeedleTailAsyncConsumer<Job>
    let ratchetManager: DoubleRatchetStateManager<SHA256>
    let keyManager: KeyManager
    let rtcSession: RTCSession
    
    var sequenceId = 0
    var logger: NeedleTailLogger
    var isRunning = false
    
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

    // MARK: - Public API

    public func feedTask(task: EncryptableTask) async throws {

        let seq = incrementId()
        let job = Job(
            id: UUID().uuidString,
            sequenceId: seq,
            task: task.task)
        
        createJob(job)

        try await startProcessingIfNeeded()
    }

    public func loadTasks(_ job: Job? = nil) async throws {
        
        if let job {
            try await jobConsumer.loadAndOrganizeTasks(job)
        } else {
            for job in jobs {
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
    }
    // MARK: - Core loop

    private func processingLoop() async throws {

        if await jobConsumer.deque.isEmpty {
            try await loadFromCache()
        }

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
                        
                        let outcome = try await process(job)
                        
                        if outcome == .paused {
                            await jobConsumer.gracefulShutdown()
                            return
                        }
                        if await jobConsumer.deque.isEmpty {
                            await jobConsumer.gracefulShutdown()
                            return
                        }
                    } catch {
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
        for job in jobs {
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
        } catch let error as RatchetError {
            // Ratchet state is out of sync - this can happen if messages arrive out of order
            // or if recipient initialization happened with the wrong header
            // Don't remove the job - keep it in cache to retry after identity is properly initialized
            logger.log(level: .error, message: "❌ JOB RATCHET ERROR: \(error) - job will be retried: \(job.id)")
            return .paused
        } catch {
            removeJob(id: job.id)
            logger.log(level: .error, message: "Job error: \(error)")
            // Keep the job in cache for now (retry semantics are handled elsewhere / future improvements).
            return .failed
        }
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
        
        // In PQSRTC, we fetch by normalized connectionId (UUID, no "#"); wire format uses "#" for IRC.
        let connectionSessionIdentity = try await keyManager.fetchConnectionIdentity(connection: outboundTask.roomId.normalizedConnectionId)
        
        let identity = connectionSessionIdentity.sessionIdentity
        
        // Get remote props for senderInitialization (unwrap remote identity with the key it was created with)
        guard let remoteProps = await identity.props(symmetricKey: connectionSessionIdentity.symmetricKey) else {
            throw RTCErrors.invalidConfiguration("Remote props not found for roomId=\(outboundTask.roomId)")
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
            sfuIdentity: outboundTask.roomId.ensureIRCChannel,
            header: message.header,
            ratchetMessage: message,
            flag: outboundTask.flag)
        
        // Send via transport - delegate to RTCSession
        try await rtcSession.sendEncryptedPacket(
            packet: encrypted,
            call: outboundTask.call)
    }
    
    private func handleStreamMessage(inboundTask: StreamTask) async throws {
        let packet = inboundTask.packet
        let roomId = packet.sfuIdentity
        
        logger.log(level: .info, message: "PQS RTC handling encrypted packet", metadata: ["roomId":"\(roomId)", "flag":"\(packet.flag)"])

        // Fetch by normalized ID (packet.sfuIdentity may have "#" from IRC).
        let connectionSessionIdentity = try await keyManager.fetchConnectionIdentity(connection: roomId.normalizedConnectionId)
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
        
        let taskJob = TaskJob(item: typedJob, priority: .standard)
        
        // Always use sequence-based insertion to ensure FIFO ordering and prevent race conditions
        await insertSequence(
            taskJob,
            sequenceId: job.sequenceId)
    }
    
    private func insertSequence(_ taskJob: TaskJob<T>, sequenceId: Int) async {
        // Since NeedleTailAsyncConsumer is an actor, all operations are atomic
        // Find the index where the new job should be inserted
        let index = await deque.firstAsyncIndex(where: {
            guard let job = $0.item as? Job else {
                return false
            }
            let currentJobSequenceId = job.sequenceId
            return currentJobSequenceId >= sequenceId // Find the first job with a sequence ID greater than or equal to the new job
        }) ?? deque.count // If no such index is found, use the end of the deque

        // Insert the new job at the found index
        // This operation is atomic since NeedleTailAsyncConsumer is an actor
        deque.insert(taskJob, at: index)
    }

    func gracefulShutdown() async {
        // Clear the deque to stop processing
        deque.removeAll()
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
