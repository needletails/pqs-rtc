import Foundation

@testable import PQSRTC

/// SDP builders derived from `ScreenShareGroupCallContract` — not from production logs.
enum ScreenShareSDPFixtures {
    static let defaultRoomId = "conf-room-alpha"

    static func screenTrackId(participant: String, roomId: String = defaultRoomId) -> String {
        ScreenShareGroupCallContract.screenTrackId(participantId: participant, roomId: roomId)
    }

    static func cameraTrackId(participant: String, roomId: String = defaultRoomId) -> String {
        ScreenShareGroupCallContract.cameraTrackId(participantId: participant, roomId: roomId)
    }

    static func audioTrackId(participant: String, roomId: String = defaultRoomId) -> String {
        ScreenShareGroupCallContract.audioTrackId(participantId: participant, roomId: roomId)
    }

    /// SFU → viewer offer when `sharer` is actively sharing (contract: `sfuForwardShareToViewer`).
    static func sfuInboundStartShareOffer(
        sharer: String,
        viewer: String = "viewer-b",
        roomId: String = defaultRoomId,
        screenSSRC: String = "900001"
    ) -> String {
        _ = viewer
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let screenId = screenTrackId(participant: sharer, roomId: roomId)
        let audioId = audioTrackId(participant: sharer, roomId: roomId)
        let screenLabel = ScreenShareGroupCallContract.screenStreamLabel(participantId: sharer)
        return """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(sharer) \(audioId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendonly
        a=msid:\(screenLabel) \(screenId)
        a=ssrc:\(screenSSRC) msid:\(screenLabel) \(screenId)
        """
    }

    /// SFU → viewer offer when sharing stopped (contract: `sfuForwardStopToViewer`).
    static func sfuInboundStopShareOffer(
        sharer: String,
        roomId: String = defaultRoomId
    ) -> String {
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let audioId = audioTrackId(participant: sharer, roomId: roomId)
        return """
        v=0
        o=- 2 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(sharer) \(audioId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=recvonly
        """
    }

    /// Raw WebRTC answer before client policy (all mids sendrecv — policy must correct mid 2).
    static func rawWebRTCAnswerAllSendRecv() -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendrecv
        """
    }

    /// Sharer → SFU raw offer when starting share (contract: `sharerStartShare`).
    static func sharerRawStartShareOffer(
        sharer: String,
        roomId: String = defaultRoomId
    ) -> String {
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let screenId = screenTrackId(participant: sharer, roomId: roomId)
        let audioId = audioTrackId(participant: sharer, roomId: roomId)
        let screenLabel = ScreenShareGroupCallContract.screenStreamLabel(participantId: sharer)
        return """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(sharer) \(audioId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=sendonly
        a=msid:\(screenLabel) \(screenId)
        """
    }

    /// Sharer → SFU raw offer when stopping share (contract: `sharerStopShare`).
    static func sharerRawStopShareOffer(
        sharer: String,
        roomId: String = defaultRoomId
    ) -> String {
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let audioId = audioTrackId(participant: sharer, roomId: roomId)
        let screenId = screenTrackId(participant: sharer, roomId: roomId)
        return """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(sharer) \(audioId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=inactive
        a=msid:- \(screenId)
        """
    }

    /// Production libwebrtc voluntary-stop shape: the mid=2 transceiver created by a remote
    /// offer advertises the sender UUID (no `screen_` prefix) with a detached msid stream and
    /// leftover ssrc attributes after the track is removed.
    static func sharerRawStopShareOfferWithDetachedUuidMsid(
        sharer: String,
        roomId: String = defaultRoomId,
        senderUuid: String = "60cdb0f5-796f-437d-9687-225ce443a9d4"
    ) -> String {
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let audioId = audioTrackId(participant: sharer, roomId: roomId)
        return """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:\(sharer) \(audioId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=inactive
        a=msid:- \(senderUuid)
        a=ssrc-group:FID 3884459946 2921474842
        a=ssrc:3884459946 cname:test
        a=ssrc:3884459946 msid:- \(senderUuid)
        a=ssrc:2921474842 cname:test
        a=ssrc:2921474842 msid:- \(senderUuid)
        """
    }

    /// SFU answer that still advertises recvonly screen mid after sharer sent inactive (invalid without normalization).
    static func sfuAnswerToStopOfferWithStaleScreenMid(
        sharer: String,
        roomId: String = defaultRoomId
    ) -> String {
        let cameraId = cameraTrackId(participant: sharer, roomId: roomId)
        let screenId = screenTrackId(participant: sharer, roomId: roomId)
        let screenLabel = ScreenShareGroupCallContract.screenStreamLabel(participantId: sharer)
        return """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:\(sharer) \(cameraId)
        m=video 9 UDP/TLS/RTP/SAVPF 100
        c=IN IP4 0.0.0.0
        a=mid:2
        a=recvonly
        a=msid:\(screenLabel) \(screenId)
        """
    }
}

enum ScreenShareSDPAssertions {
    static func resolveParticipantId(from label: String) -> String? {
        if label.hasPrefix(RTCSession.screenTrackPrefix) {
            return RTCSession.participantIdFromScreenShareId(label)
        }
        if label.hasPrefix("streamId_\(RTCSession.screenTrackPrefix)") {
            let trimmed = String(label.dropFirst("streamId_".count))
            return RTCSession.participantIdFromScreenShareId(trimmed)
        }
        return label
    }
}

/// Contract-driven scenario: models room screen-share state and SFU-forwarded offers.
struct ScreenShareGroupCallScenarioSimulator {
    let roomId: String
    private(set) var activeSharerId: String?

    init(roomId: String = ScreenShareSDPFixtures.defaultRoomId) {
        self.roomId = roomId
    }

    mutating func startShare(participantId: String) {
        precondition(
            activeSharerId == nil,
            "exclusive share: stop current sharer before starting another"
        )
        activeSharerId = participantId
    }

    mutating func stopShare() {
        activeSharerId = nil
    }

    mutating func handoff(to newSharerId: String) {
        activeSharerId = nil
        activeSharerId = newSharerId
    }

    func sfuOfferToViewer(viewerId: String) -> String? {
        guard let sharer = activeSharerId else { return nil }
        return ScreenShareSDPFixtures.sfuInboundStartShareOffer(
            sharer: sharer,
            viewer: viewerId,
            roomId: roomId
        )
    }

    func sfuStopOfferToViewer(viewerId: String, formerSharer: String) -> String {
        _ = viewerId
        return ScreenShareSDPFixtures.sfuInboundStopShareOffer(
            sharer: formerSharer,
            roomId: roomId
        )
    }
}
