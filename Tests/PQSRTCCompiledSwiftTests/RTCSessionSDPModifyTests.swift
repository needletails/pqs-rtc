import Foundation
import Testing

@testable import PQSRTC

@Suite
struct RTCSessionSDPModifyTests {
    @Test
    func modifySDP_normalizesNewlines_andAppendsTrailingNewline() async {
        let session = RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

        let input = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n\r\n"
        let output = await session.modifySDP(sdp: input)

        #expect(output.contains("\r") == false)
        #expect(output.hasSuffix("\n"))
        #expect(output.contains("v=0\n"))

        await session.shutdown(with: nil)
    }

    @Test
    func modifySDP_rewritesAudioDirectionToSendRecv_onlyOncePerAudioSection() async {
        let session = RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

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
        let session = RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

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
    func modifySDP_downgradesH264ProfileLevelId() async {
        let session = RTCSession(iceServers: [], username: "u", password: "p", delegate: nil)

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
        #expect(output.contains("profile-level-id=42e01f"))
        #expect(output.contains("profile-level-id=42e034") == false)

        await session.shutdown(with: nil)
    }
}
