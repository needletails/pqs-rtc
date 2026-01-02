import Foundation
import Testing
#if canImport(WebRTC)
@preconcurrency import WebRTC
@testable import PQSRTC

@Suite
struct IceCandidateTests {
    @Test
    func validationErrors() {
        #expect(throws: Error.self) {
            _ = try IceCandidate(from: RTCIceCandidate(sdp: " ", sdpMLineIndex: 0, sdpMid: "0"), id: 1)
        }
        #expect(throws: Error.self) {
            _ = try IceCandidate(from: RTCIceCandidate(sdp: "candidate:...", sdpMLineIndex: -1, sdpMid: "0"), id: 1)
        }
        #expect(throws: Error.self) {
            _ = try IceCandidate(from: RTCIceCandidate(sdp: "candidate:...", sdpMLineIndex: 0, sdpMid: "0"), id: -1)
        }
    }

    @Test
    func helpers() throws {
        let cand = try IceCandidate(
            from: RTCIceCandidate(
                sdp: "candidate: 1 1 UDP 2122252543 192.168.1.2 56143 typ host",
                sdpMLineIndex: 0,
                sdpMid: "0"
            ),
            id: 42
        )

        #expect(cand.id == 42)
        #expect(cand.isLocal == true)
        #expect(cand.isRelay == false)
        #expect(cand.candidateType == "host")
        #expect(cand.description.contains("id: 42"))

        let relay = try IceCandidate(
            from: RTCIceCandidate(
                sdp: "candidate: 2 1 UDP 1234 1.2.3.4 9999 typ relay",
                sdpMLineIndex: 0,
                sdpMid: nil
            ),
            id: 9
        )

        #expect(relay.isRelay == true)
        #expect(relay.candidateType == "relay")

        let rtc = cand.rtcIceCandidate
        #expect(rtc.sdp == cand.sdp)
        #expect(rtc.sdpMLineIndex == cand.sdpMLineIndex)
    }
}
#endif
