import Testing

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

@Suite
struct WebRTCStateWrappersTests {
    @Test
    func signalingStateDescriptionMapping() {
        #expect(SPTSignalingState(state: .stable).description == "stable")
        #expect(SPTSignalingState(state: .haveLocalOffer).description == "haveLocalOffer")
        #expect(SPTSignalingState(state: .haveRemoteOffer).description == "haveRemoteOffer")
    }

    @Test
    func iceGatheringStateDescriptionMapping() {
        #expect(SPTIceGatheringState(state: .new).description == "new")
        #expect(SPTIceGatheringState(state: .gathering).description == "gathering")
        #expect(SPTIceGatheringState(state: .complete).description == "complete")
    }

    @Test
    func iceConnectionStateDescriptionMapping() {
        #expect(SPTIceConnectionState(state: .new).description == "new")
        #expect(SPTIceConnectionState(state: .checking).description == "checking")
        #expect(SPTIceConnectionState(state: .connected).description == "connected")
        #expect(SPTIceConnectionState(state: .failed).description == "failed")
    }

    @Test
    func peerConnectionStateDescriptionMapping() {
        #expect(SPTPeerConnectionState(state: .new).description == "new")
        #expect(SPTPeerConnectionState(state: .connected).description == "connected")
        #expect(SPTPeerConnectionState(state: .disconnected).description == "disconnected")
        #expect(SPTPeerConnectionState(state: .closed).description == "closed")
    }
}
#endif
