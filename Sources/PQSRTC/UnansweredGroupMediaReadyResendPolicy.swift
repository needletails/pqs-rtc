import Foundation

/// One-shot resend of source-scoped SFU `mediaReady` when the client already encrypted
/// readiness but inbound group media never started.
///
/// The SFU will not forward until it records this receiver's source key. Apple can log
/// "Sent SFU group media readiness" after encrypt while the ciphertext never arrives.
/// Later ICE candidates still send, so this is not a hung FIFO — the readiness packet
/// was dropped or overtaken. Destructive renderer recovery stays closed on flat inbound.
///
/// Bound: one resend per source generation. A later advancing-ingress event clears the
/// generation so a future hold-off can send again. Not a timer retry loop.
enum UnansweredGroupMediaReadyResendPolicy {
    static func shouldResendUnansweredGroupMediaReady(
        isGroupOrConference: Bool,
        sourceKeyInstalled: Bool,
        inboundFlowIsAdvancing: Bool,
        confirmedWireSendForSource: Bool,
        wireSendInFlightForSource: Bool,
        alreadyResentForCurrentReadyGeneration: Bool
    ) -> Bool {
        guard isGroupOrConference else { return false }
        guard sourceKeyInstalled else { return false }
        guard !inboundFlowIsAdvancing else { return false }
        // A completed IRC PRIVMSG write is the event that replaces the old "lost
        // ciphertext" recovery. Extra encrypts after that advance the ratchet
        // and the SFU then fails later answers with maxSkippedHeadersExceeded.
        guard !confirmedWireSendForSource else { return false }
        // While the first write is still in the lane, inbound is flat by definition.
        // Resending would encrypt a second mediaReady and another ratchet step.
        guard !wireSendInFlightForSource else { return false }
        guard !alreadyResentForCurrentReadyGeneration else { return false }
        return true
    }

    static func shouldClearUnansweredResendGeneration(
        inboundFlowIsAdvancing: Bool
    ) -> Bool {
        inboundFlowIsAdvancing
    }
}
