import Foundation

/// Pre-encrypt gate for group SFU ICE candidates.
///
/// Candidates already fed into the ratchet lane must stay in FIFO order. This
/// policy only decides what happens to an un-encrypted `IceCandidate` before
/// `feedTask`. Dropping an already-encrypted packet would skip a ratchet header.
enum SfuOutboundIceCandidateSendPolicy {
    enum Decision: Equatable {
        case encryptNow
        case keepBuffered
        case dropBuffered
    }

    /// - Parameters:
    ///   - isGroupOrConference: Group/conference SFU rooms only. 1:1 always encrypts.
    ///   - iceIsConnectedOrCompleted: PeerConnection ICE already connected/completed.
    ///   - hasPendingOfferOrAnswer: `.offer` or `.answer` still queued or in `outboundSends`.
    ///     `.mediaReady` is not an input — mediaReady depends on ICE being up.
    ///   - isPreConnectJoinBurst: Candidate came from the pre-connect deque drain.
    static func decide(
        isGroupOrConference: Bool,
        iceIsConnectedOrCompleted: Bool,
        hasPendingOfferOrAnswer: Bool,
        isPreConnectJoinBurst: Bool
    ) -> Decision {
        guard isGroupOrConference else { return .encryptNow }
        if hasPendingOfferOrAnswer { return .keepBuffered }
        if iceIsConnectedOrCompleted, isPreConnectJoinBurst { return .dropBuffered }
        return .encryptNow
    }
}
