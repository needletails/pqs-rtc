import Foundation

/// When source-scoped SFU `mediaReady` may wait on the calling stack.
///
/// `CallManager.applySfuGroupSenderKey` awaits `sendSfuGroupMediaReady`, then
/// distributes the local sender key and can apply the next `call_cipher`.
/// The IRC write is a sibling outbound-lane job. Awaiting it on that actor
/// holds call-control until the write completes — Device2 encrypted
/// `mediaReady` immediately and logged "Sent" ~2 minutes later, after leave
/// flushed the lane. SFU will not forward until it records readiness.
enum SfuGroupMediaReadySendPolicy {
    static func shouldAwaitMediaReadySendOnCallingStack(
        calledFromSharedCallControlActor: Bool
    ) -> Bool {
        !calledFromSharedCallControlActor
    }
}
