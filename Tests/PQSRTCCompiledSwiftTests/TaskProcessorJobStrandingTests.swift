import Foundation
import Testing

@testable import PQSRTC

/// Tests that verify the TaskProcessor drains all queued jobs correctly.
///
/// These tests target a potential race condition where a job added to the `jobs`
/// cache via `feedTask` while the processing loop is running can be stranded:
///
/// 1. `processingLoop` processes the last deque item and calls
///    `await jobConsumer.deque.isEmpty` → true
/// 2. During that await, `feedTask` adds a job to `jobs` but `tryStart()` returns
///    false (isRunning == true), so no new loop is started
/// 3. The processing loop returns without re-checking `jobs`
/// 4. `stop()` runs → isRunning = false, but nobody re-reads `jobs`
///
/// The timing window is narrow and usually self-healing (the next feedTask picks
/// up stranded jobs), but the invariant tested here is: after all feedTask calls
/// complete, no jobs should remain unprocessed in the `jobs` cache.
@Suite(.serialized)
struct TaskProcessorJobStrandingTests {

    private func makeSession() async -> RTCSession {
        await RTCSession(
            iceServers: [],
            username: "u",
            password: "p",
            delegate: nil
        )
    }

    private func makeCall(id: String) throws -> Call {
        let sender = try Call.Participant(secretName: "s", nickname: "S", deviceId: "sd")
        let recipient = try Call.Participant(secretName: "r", nickname: "R", deviceId: "rd")
        return try Call(sharedCommunicationId: id, sender: sender, recipients: [recipient])
    }

    private func makeWriteTask(call: Call) -> EncryptableTask {
        let writeTask = WriteTask(
            data: Data("test-payload".utf8),
            roomId: call.sharedCommunicationId,
            flag: .offer,
            call: call
        )
        return EncryptableTask(task: .writeMessage(writeTask))
    }

    /// Feeds multiple tasks from separate concurrent tasks and verifies
    /// all jobs are drained from the cache afterwards.
    ///
    /// Without the defensive post-loop drain check in `startProcessingIfNeeded`,
    /// a task fed while the processing loop is between its final deque-empty check
    /// and `stop()` can be stranded in `jobs` indefinitely.
    @Test("concurrent feedTask calls should not strand jobs in cache")
    func concurrentFeedTaskDoesNotStrandJobs() async throws {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(id: "stranding-test")
        let processor = await session.taskProcessor

        let iterations = 20
        for _ in 0..<iterations {
            let task1 = makeWriteTask(call: call)
            let task2 = makeWriteTask(call: call)

            let t1 = Task {
                try? await processor.feedTask(task: task1)
            }
            await Task.yield()
            let t2 = Task {
                try? await processor.feedTask(task: task2)
            }

            await t1.value
            await t2.value
        }

        // Allow any in-flight processing to drain
        try await Task.sleep(nanoseconds: 100_000_000)

        let remainingJobs = await processor.jobs
        #expect(remainingJobs.isEmpty, "Expected all jobs to be drained, but \(remainingJobs.count) remain stranded in cache")
    }

    /// Feeds a burst of tasks as fast as possible and ensures none remain in cache.
    @Test("rapid sequential feedTask should drain all jobs")
    func rapidSequentialFeedTaskDrainsAll() async throws {
        let session = await makeSession()
        defer { Task { await session.shutdown(with: nil) } }

        let call = try makeCall(id: "rapid-test")
        let processor = await session.taskProcessor

        for _ in 0..<10 {
            let task = makeWriteTask(call: call)
            try? await processor.feedTask(task: task)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let remainingJobs = await processor.jobs
        #expect(remainingJobs.isEmpty, "Expected all jobs to be drained, but \(remainingJobs.count) remain")
    }
}
