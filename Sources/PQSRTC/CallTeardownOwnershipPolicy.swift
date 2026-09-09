import Foundation

/// Ownership rules for overlapping leave/rejoin of the same SFU room.
///
/// A group rejoin keeps the same `sharedCommunicationId` (room UUID) and a new
/// `Call.id`. Leftover end/shutdown from the previous attempt must not retire
/// the live crypto stack or close the new PeerConnection.
public enum CallTeardownOwnershipPolicy {
    /// Skip leftover shutdown when a newer attempt already owns this room.
    public static func shouldSkipShutdownForLiveAttempt(
        endingCallId: UUID,
        liveCallId: UUID,
        endingRoomId: String,
        liveRoomId: String
    ) -> Bool {
        guard endingCallId != liveCallId else { return false }
        return endingRoomId.normalizedConnectionId == liveRoomId.normalizedConnectionId
    }

    /// App-layer leftover teardown may run only when it does not share the room
    /// with the live attempt. `hasConnection(roomUUID)` is a false positive on
    /// rejoin because both attempts use that id.
    public static func shouldApplyStaleAppTeardown(
        currentAttemptDiffers: Bool,
        currentSharesRoomWithCleanup: Bool
    ) -> Bool {
        guard currentAttemptDiffers else { return true }
        return !currentSharesRoomWithCleanup
    }

    /// Retire only the crypto generation this teardown started with. A rejoin
    /// that rebuilt mid-shutdown must keep its live stack.
    public static func shouldRetireCryptoStack(
        teardownGeneration: UInt64,
        liveGeneration: UInt64
    ) -> Bool {
        teardownGeneration == liveGeneration
    }

    /// Apply `RTCSession.leave` only when the registered group still belongs
    /// to this attempt. The registry is keyed by room id, so a newer same-room
    /// rejoin owns the slot when `Call.id` differs.
    public static func shouldApplyGroupLeave(
        endingCallId: UUID,
        registeredCallId: UUID
    ) -> Bool {
        endingCallId == registeredCallId
    }
}
