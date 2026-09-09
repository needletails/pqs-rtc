import Foundation

/// After PART, Apple keeps the departed camera m-line. Rejoin adds a new receiving
/// mid. The first `mediaReady` often encrypts while only the leftover exists; SFU
/// then treats a later identical readiness as PLI-only. The mapping upgrade onto
/// a live receiving mid is the event that must start a fresh readiness generation.
enum SfuRejoinedReceiverMappingPolicy {
    /// A leftover PART mapping is not a first-join attach. First-join has no previous
    /// track and must not encrypt a second `mediaReady` (that advances the ratchet).
    static func shouldEmitMediaReadyAfterReceivingMappingUpgrade(
        previousTrackIsReceiving: Bool,
        newTrackIsReceiving: Bool,
        previousTrackId: String?,
        newTrackId: String
    ) -> Bool {
        let previous = previousTrackId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let next = newTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !next.isEmpty, previous != next else { return false }
        return newTrackIsReceiving && !previousTrackIsReceiving
    }

    static func shouldResetMediaReadyGenerationAfterDepartedMappingRemoved(
        mappingRemoved: Bool
    ) -> Bool {
        mappingRemoved
    }
}
