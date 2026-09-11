import Foundation

/// Leftover SFU receiver tracks after a participant PART.
///
/// Apple WebRTC keeps the departed peer's m-line. If that camera track stays
/// enabled on an inactive transceiver, a later rejoin allocates new mids and
/// the leftover can steal the relay. Device2 then attaches the new mid while
/// inbound RTP never arrives.
enum SfuDepartedReceiverTrackPolicy {
    /// Unmap is not enough: the departed camera track must be disabled.
    static func shouldDisableDepartedSfuReceiverTrack(mappingRemoved: Bool) -> Bool {
        mappingRemoved
    }

    /// Unresolved fallback must ignore leftover inactive / send-only m-lines,
    /// the local publish transceiver (mid 1 is sendrecv camera), and tracks
    /// already disabled after PART. Apple can keep `sendRecv` on an `a=inactive`
    /// leftover; `track.isEnabled == false` is the reliable leftover signal.
    static func shouldIncludeUnresolvedSfuReceiverCandidate(
        transceiverIsReceivingRemoteMedia: Bool,
        senderHasLocalTrack: Bool,
        trackIsEnabled: Bool
    ) -> Bool {
        transceiverIsReceivingRemoteMedia && !senderHasLocalTrack && trackIsEnabled
    }

    /// After setRemoteSDP, disable leftover tracks whose transceiver can no longer receive.
    /// The reserved screen-share contract mid stays enabled even while `inactive`.
    static func shouldDisableLeftoverSfuReceiverTrackAfterRemoteSDP(
        transceiverIsReceivingRemoteMedia: Bool,
        trackIsEnabled: Bool,
        isReservedScreenContractTransceiver: Bool
    ) -> Bool {
        trackIsEnabled && !transceiverIsReceivingRemoteMedia && !isReservedScreenContractTransceiver
    }

    /// After PART the leftover camera stays in the participant map. Reconcile must
    /// not keep that mapping or the live rejoin mid is never claimed.
    static func shouldKeepExistingMappedSfuReceiver(
        existingTrackIsEnded: Bool,
        existingTrackIsReceivingCandidate: Bool
    ) -> Bool {
        !existingTrackIsEnded && existingTrackIsReceivingCandidate
    }

    /// After PART, leftover SDP labels / remembered Android camera ids must not
    /// put the departed publisher back on the connection map (Device3 16:17:
    /// 1:1 then `track added` remounted the 16:9 grid).
    static func shouldRematerializePrunedAndroidCameraMapping(
        participantWasPruned: Bool
    ) -> Bool {
        !participantWasPruned
    }
}
