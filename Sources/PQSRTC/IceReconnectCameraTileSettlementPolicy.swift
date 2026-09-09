import Foundation

/// Event-driven camera-tile settlement after ICE returns on the same PeerConnection.
///
/// A brief ICE `disconnected`/`failed` can rotate WebRTC receiver wrappers without an SFU
/// renegotiation. Join-path `checking` → `connected` must not use this path.
enum IceReconnectCameraTileSettlementPolicy {
    static func isIceMediaPathDisruption(_ iceState: String) -> Bool {
        iceState == "disconnected" || iceState == "failed"
    }

    static func isIceMediaPathRecovered(_ iceState: String) -> Bool {
        iceState == "connected" || iceState == "completed"
    }

    static func shouldSettleRemoteCameraTiles(
        newIceState: String,
        hadMediaPathDisruption: Bool,
        isGroupOrConference: Bool,
        hasMappedRemoteCameraParticipants: Bool,
        renegotiationInFlight: Bool,
        relayFallbackRetrying: Bool
    ) -> Bool {
        guard isIceMediaPathRecovered(newIceState) else { return false }
        guard hadMediaPathDisruption else { return false }
        guard isGroupOrConference else { return false }
        guard hasMappedRemoteCameraParticipants else { return false }
        guard !renegotiationInFlight else { return false }
        guard !relayFallbackRetrying else { return false }
        return true
    }

    static func participantIdsNeedingIceReconnectTileRefresh(
        allMappedParticipantIds: [String]
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in allMappedParticipantIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered.sorted()
    }
}
