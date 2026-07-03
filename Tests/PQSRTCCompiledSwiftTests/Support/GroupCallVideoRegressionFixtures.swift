import Foundation

/// SDP fixtures derived from the 2026-06-26 three-device group call logs
/// (room `493b6051-39f0-493d-aace-7683f2bfa9e2`, Android participant `frank`).
enum GroupCallVideoRegressionFixtures {
    static let roomUUID = "493b6051-39f0-493d-aace-7683f2bfa9e2"

    /// SFU renegotiation offer when the first remote participant (`nudge`) joins.
    /// Android log @ 10:07:31.955 — `video(mid=2,dir=recvonly,msid=0,...)`.
    static func firstParticipantJoinRemoteOffer() -> String {
        """
        v=0
        o=- 2491581054866341607 3 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:nudge audio_nudge
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:nudge video_nudge
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:2
        a=recvonly
        """
    }

    /// Raw WebRTC answer before client policy for the first join renegotiation.
    /// Android log @ 10:07:32.310 — `video(mid=2,dir=inactive,msid=0,...)`.
    static func firstParticipantJoinRawAnswer() -> String {
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
        a=msid:local_audio audio_track
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:local_video video_track
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:2
        a=inactive
        """
    }

    /// SFU renegotiation offer when a second remote participant (`echo`) joins.
    static func secondParticipantJoinRemoteOffer() -> String {
        """
        v=0
        o=- 2491581054866341608 4 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2 3 4
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:nudge audio_nudge
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:nudge video_nudge
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:2
        a=recvonly
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:3
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:4
        a=recvonly
        """
    }

    /// Raw WebRTC answer before client policy for the second join renegotiation.
    static func secondParticipantJoinRawAnswer() -> String {
        """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=group:BUNDLE 0 1 2 3 4
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:0
        a=sendrecv
        a=msid:local_audio audio_track
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:1
        a=sendrecv
        a=msid:local_video video_track
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:2
        a=inactive
        a=msid:local_video video_track
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        c=IN IP4 0.0.0.0
        a=mid:3
        a=recvonly
        m=video 9 UDP/TLS/RTP/SAVPF 96
        c=IN IP4 0.0.0.0
        a=mid:4
        a=recvonly
        """
    }
}

enum SDPTestHelpers {
    static func videoDirection(forMid mid: String, in sdp: String) -> String? {
        let summary = RTCSdpDiagnostics.summary(sdp)
        for section in summary.split(separator: ";") {
            let text = String(section)
            guard text.hasPrefix("video(mid=\(mid),") else { continue }
            guard let dirRange = text.range(of: "dir=") else { return nil }
            let afterDir = text[dirRange.upperBound...]
            return afterDir.split(separator: ",").first.map(String.init)
        }
        return nil
    }
}
