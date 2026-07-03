import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct RTCSessionSDPModifyTests {
    @Test
    func modifySDP_normalizesNewlines_andAppendsTrailingNewline() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let input = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n\r\n"
        let output = await session.modifySDP(sdp: input)

        #expect(output.contains("\r") == false)
        #expect(output.hasSuffix("\n"))
        #expect(output.contains("v=0\n"))

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_rewritesAudioDirectionToSendRecv_onlyOncePerAudioSection() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=recvonly",
            "a=sendonly"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(sdp: input, hasVideo: true)

        #expect(output.contains("a=sendrecv"))
        // Current implementation stops scanning audio section after first direction rewrite.
        #expect(output.contains("a=sendonly"))

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_rewritesVideoDirection_onlyWhenHasVideoTrue() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let baseLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=inactive"
        ]
        let input = baseLines.joined(separator: "\n") + "\n"

        let withVideo = await session.modifySDP(sdp: input, hasVideo: true)
        #expect(withVideo.contains("a=sendrecv"))
        #expect(withVideo.contains("a=inactive") == false)

        let withoutVideo = await session.modifySDP(sdp: input, hasVideo: false)
        #expect(withoutVideo.contains("a=inactive"))

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_preservesScreenShareDirectionWhenHasVideoTrue() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:2",
            "a=sendonly",
            "a=msid:screen_nudge screen_nudge_#conf-room"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(sdp: input, hasVideo: true)

        #expect(output.contains("a=sendonly"))
        #expect(output.contains("a=sendrecv") == false)
        #expect(RTCSession.screenShareVideoMids(in: input) == ["2"])

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_preservesExplicitVideoMidDirectionWithoutScreenMsid() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:2",
            "a=recvonly"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(
            sdp: input,
            hasVideo: true,
            preserveVideoDirectionsForMids: ["2"]
        )

        #expect(output.contains("a=recvonly"))
        #expect(output.contains("a=sendrecv") == false)

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_preservesRecvOnlyVideoMidWithoutLocalMedia() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:2",
            "a=recvonly",
            "a=rtpmap:100 VP8/90000"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(sdp: input, hasVideo: true)

        #expect(output.contains("a=recvonly"))
        #expect(output.contains("a=sendrecv") == false)
        #expect(RTCSession.receiveOnlyVideoMidsWithoutLocalMedia(in: input) == ["2"])

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_preservesRecvOnlyRelayAudioMidWithoutLocalMedia() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:0",
            "a=sendrecv",
            "a=msid:local_audio audio_track",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:3",
            "a=recvonly",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:2",
            "a=inactive",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:4",
            "a=recvonly"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(sdp: input, hasVideo: true)

        #expect(RTCSession.receiveOnlyAudioMidsWithoutLocalMedia(in: input) == ["3"])
        #expect(RTCSession.receiveOnlyVideoMidsWithoutLocalMedia(in: input) == ["4"])
        #expect(RTCSession.inactiveVideoMidsWithoutLocalMedia(in: input) == ["2"])
        #expect(output.contains("a=mid:3\na=recvonly"))
        #expect(output.contains("a=mid:2\na=inactive"))
        #expect(output.contains("a=mid:4\na=recvonly"))

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_preservesSendOnlyAnswerVideoWhenRemoteSfuPlaceholderMidProvided() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let answerLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 100",
            "a=mid:1",
            "a=sendonly",
            "a=msid:streamId_nudge video_nudge_track"
        ]
        let answer = answerLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(
            sdp: answer,
            hasVideo: true,
            preserveVideoDirectionsForMids: ["1"]
        )

        #expect(output.contains("a=sendonly"))
        #expect(output.contains("a=sendrecv") == false)

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_downgradesH264ProfileLevelId() async {
        let session = await RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let inputLines = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e034",
            "a=recvonly"
        ]
        let input = inputLines.joined(separator: "\n") + "\n"

        let output = await session.modifySDP(sdp: input, hasVideo: true)
        // IMPORTANT:
        // We cap H264 Constrained Baseline from level 5.2 (42e034) down to level 4.0 (42e028),
        // NOT down to 3.1 (42e01f). For 1080p sources, forcing 3.1 can cause sender-side stalls.
        #expect(output.contains("profile-level-id=42e028"))
        #expect(output.contains("profile-level-id=42e034") == false)

        await session.shutdown(with: nil)
    }
}
