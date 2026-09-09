import Foundation

/// When an inbound SFU renegotiation answer may wait on the calling stack.
///
/// Inbound `.offer` decrypt runs inside `TaskProcessor.process`. The answer
/// write is a sibling job on the same loop. Awaiting that write from the
/// inbound job deadlocks: the loop will not encrypt the answer until
/// `process()` returns.
enum SfuRenegotiationAnswerSendPolicy {
    static func shouldAwaitAnswerSendOnCallingStack(
        calledFromTaskProcessorInboundJob: Bool
    ) -> Bool {
        !calledFromTaskProcessorInboundJob
    }
}
