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
    /// Parses `a=` direction for a video section with the given mid. Kept local so tests do not
    /// depend on ``RTCSdpDiagnostics`` (which may be unavailable under Skip transpile / non-WebRTC builds).
    static func videoDirection(forMid mid: String, in sdp: String) -> String? {
        let normalized = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var currentKind: String?
        var currentMid: String?
        var currentDirection: String?
        for line in lines {
            if line.hasPrefix("m=") {
                let body = line.dropFirst("m=".count)
                currentKind = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
                currentMid = nil
                currentDirection = nil
                continue
            }
            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                continue
            }
            switch line {
            case "a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive":
                currentDirection = String(line.dropFirst("a=".count))
            default:
                break
            }
            if currentKind == "video", currentMid == mid, let currentDirection {
                return currentDirection
            }
        }
        return nil
    }
}
