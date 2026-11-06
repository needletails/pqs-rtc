import Foundation
import Testing

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)

/// The sender-transformer drain must still wait when teardown runs in a cancelled task.
///
/// Teardown is often reached from a task that has just cancelled itself: the relay-fallback
/// timer cancels its own `timeoutTask` before discarding the attempt, and the disconnect-grace
/// task calls `finishEndConnection`, which cancels `disconnectGraceTask`. A cancelled task's
/// `Task.sleep` returns at once, which would skip the drain that keeps the RTP senders from
/// being destroyed under in-flight encrypted frames.
@Suite(.serialized)
struct SenderTeardownDrainCancellationTests {
    @Test("The sender-transformer drain still waits when teardown runs in a cancelled task")
    func drainWaitsWhenTeardownTaskIsCancelled() async throws {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let (wasCancelled, elapsed) = await Task {
            // Mirror the self-cancelling teardown tasks.
            withUnsafeCurrentTask { $0?.cancel() }
            let wasCancelled = Task.isCancelled
            let elapsed = await ContinuousClock().measure {
                await session.drainAppleSenderFrameTransformersBeforeSenderTeardown()
            }
            return (wasCancelled, elapsed)
        }.value

        #expect(wasCancelled)
        #expect(elapsed >= .milliseconds(80), "drain returned after \(elapsed) in a cancelled task")

        await session.shutdown(with: nil)
    }
}
#endif
