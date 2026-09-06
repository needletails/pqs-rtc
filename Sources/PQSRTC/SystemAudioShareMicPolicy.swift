import Foundation

/// Decides whether a user mute/unmute request should update capture suppression while
/// system audio is mixed onto the outbound audio track.
enum SystemAudioShareMicPolicy {
    static func suppressionForAudioIntent(
        shareIsActive: Bool,
        audioTrackRequestedEnabled: Bool,
        isMixerForcedTrackEnable: Bool
    ) -> Bool? {
        guard shareIsActive, !isMixerForcedTrackEnable else { return nil }
        return !audioTrackRequestedEnabled
    }
}
