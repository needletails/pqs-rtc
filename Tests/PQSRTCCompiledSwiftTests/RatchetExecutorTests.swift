import Dispatch
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RatchetExecutorTests {
    @Test
    func checkIsolatedOnQueueDoesNotTrap() {
        let queue = DispatchQueue(label: "ratchet-executor-tests")
        let executor = RatchetExecutor(queue: queue)

        queue.sync {
            executor.checkIsolated()
        }
    }
}
