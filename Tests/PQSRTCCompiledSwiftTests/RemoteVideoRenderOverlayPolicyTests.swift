import Testing
@testable import PQSRTC

@Suite
struct RemoteVideoRenderOverlayPolicyTests {
    @Test("Brief callback gap does not show pause overlay")
    func briefGapHidesOverlay() {
        var showsFrozen = false
        let show = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: 5_000,
            inboundFlowState: .stalledIngress,
            showsFrozen: &showsFrozen)
        #expect(show == false)
        #expect(showsFrozen == false)
    }

    @Test("Advancing ingress never shows pause overlay even after long callback gap")
    func advancingIngressHoldsLastFrame() {
        var showsFrozen = true
        let show = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: 20_000,
            inboundFlowState: .advancingIngress,
            showsFrozen: &showsFrozen)
        #expect(show == false)
        #expect(showsFrozen == false)
    }

    @Test("Decode stalled with advancing RTP holds last frame without pause overlay")
    func decodeStalledHoldsLastFrame() {
        var showsFrozen = false
        let show = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: 20_000,
            inboundFlowState: .decodeStalled,
            showsFrozen: &showsFrozen)
        #expect(show == false)
        #expect(showsFrozen == false)
    }

    @Test("Prolonged stalled ingress shows pause overlay")
    func prolongedStalledIngressShowsOverlay() {
        var showsFrozen = false
        let show = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: 13_000,
            inboundFlowState: .stalledIngress,
            showsFrozen: &showsFrozen)
        #expect(show == true)
        #expect(showsFrozen == true)
    }

    @Test("Resumed callbacks hide overlay quickly")
    func resumedCallbacksHideOverlay() {
        var showsFrozen = true
        let show = RemoteVideoRenderOverlayPolicy.shouldShowRenderFrozenOverlay(
            frameCallbackAgeMs: 900,
            inboundFlowState: .stalledIngress,
            showsFrozen: &showsFrozen)
        #expect(show == false)
        #expect(showsFrozen == false)
    }
}
