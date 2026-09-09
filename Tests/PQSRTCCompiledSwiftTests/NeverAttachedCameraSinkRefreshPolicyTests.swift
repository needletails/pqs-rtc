import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct NeverAttachedCameraSinkRefreshPolicyTests {
    @Test("never-attached tile with advancing decode refreshes the camera sink")
    func neverAttachedAdvancingIngressRefreshesSink() {
        #expect(
            NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink(
                inboundFlowIsAdvancing: true,
                hasAnyCallbacks: false,
                callbackAgeMs: -1,
                expectationAgeMs: 12_000
            )
        )
    }

    @Test("live tiles with callbacks do not refresh while decode is advancing")
    func liveCallbacksDoNotRefreshWhileIngressAdvances() {
        #expect(
            NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink(
                inboundFlowIsAdvancing: true,
                hasAnyCallbacks: true,
                callbackAgeMs: 12_000,
                expectationAgeMs: 12_000
            ) == false
        )
    }

    @Test("join-path grace period does not refresh a never-attached tile")
    func joinPathGraceDoesNotRefreshNeverAttachedTile() {
        #expect(
            NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink(
                inboundFlowIsAdvancing: true,
                hasAnyCallbacks: false,
                callbackAgeMs: -1,
                expectationAgeMs: 3_000
            ) == false
        )
    }

    @Test("non-advancing inbound is not this sink-refresh path")
    func nonAdvancingInboundDoesNotUseSinkRefreshPath() {
        #expect(
            NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink(
                inboundFlowIsAdvancing: false,
                hasAnyCallbacks: false,
                callbackAgeMs: -1,
                expectationAgeMs: 30_000
            ) == false
        )
    }

    @Test("Apple attach identity includes the live track object")
    func appleAttachIdentityIncludesLiveTrackObject() {
        let renderer = "ObjectIdentifier(0x2)"
        let sameTrack = AppleRemoteVideoTrackAttachPolicy.participantRendererAttachmentValue(
            trackId: "video_mm26",
            receivingMid: "4",
            trackObjectIdentity: "ObjectIdentifier(0x10)",
            rendererObjectIdentity: renderer
        )
        let rotatedTrack = AppleRemoteVideoTrackAttachPolicy.participantRendererAttachmentValue(
            trackId: "video_mm26",
            receivingMid: "4",
            trackObjectIdentity: "ObjectIdentifier(0x99)",
            rendererObjectIdentity: renderer
        )
        #expect(sameTrack.contains("track:ObjectIdentifier(0x10)"))
        #expect(
            AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
                cachedAttachmentValue: sameTrack,
                liveAttachmentValue: sameTrack
            )
        )
        #expect(
            AppleRemoteVideoTrackAttachPolicy.shouldSkipParticipantRendererAttach(
                cachedAttachmentValue: sameTrack,
                liveAttachmentValue: rotatedTrack
            ) == false
        )
    }

#if canImport(WebRTC)
    @Test("destructive decode-stall recovery stays closed for never-attached advancing ingress")
    func destructiveRecoveryStaysClosedForNeverAttachedAdvancingIngress() {
        let advancing = RTCSession.InboundVideoFlowCheck(
            state: .advancingIngress,
            likelyCause: "inbound_video_advancing",
            audioPacketsReceived: 27047,
            packetsReceived: 56027,
            framesReceived: 4741,
            framesDecoded: 5716,
            deltaAudioPacketsReceived: 147,
            deltaPacketsReceived: 331,
            deltaFramesReceived: 31,
            deltaFramesDecoded: 32,
            dtlsState: "connected",
            selectedPairState: "succeeded"
        )
        #expect(
            RTCSession.shouldAttemptInboundRemoteVideoRendererRecovery(
                inboundFlow: advancing,
                callbackAgeMs: -1,
                hasAnyCallbacks: false,
                expectationAgeMs: 292_824
            ) == false
        )
    }
#endif

    @Test("Apple handlers sink-refresh never-attached advancing tiles without decode-stall recovery")
    func appleHandlersUseSinkRefreshNotDecodeStallRecovery() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ios = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift"
            ),
            encoding: .utf8
        )
        let mac = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift"
            ),
            encoding: .utf8
        )
        let video = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Video.swift"
            ),
            encoding: .utf8
        )
        #expect(ios.contains("NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink"))
        #expect(mac.contains("NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink"))
        #expect(ios.contains("refreshNeverAttachedParticipantCameraSinkIfNeeded"))
        #expect(mac.contains("refreshNeverAttachedParticipantCameraSinkIfNeeded"))
        #expect(video.contains("refreshNeverAttachedParticipantCameraSinkIfNeeded"))
        #expect(video.contains("Refreshing never-attached camera sink after advancing ingress"))
        #expect(!neverAttachedBranchCallsDecodeStallRecovery(ios))
        #expect(!neverAttachedBranchCallsDecodeStallRecovery(mac))
    }

    private func neverAttachedBranchCallsDecodeStallRecovery(_ source: String) -> Bool {
        guard let start = source.range(
            of: "NeverAttachedCameraSinkRefreshPolicy.shouldRefreshRemoteCameraSink"
        ) else {
            return true
        }
        let searchRange = start.upperBound..<(
            source.range(
                of: "shouldAttemptInboundRemoteVideoRendererRecovery",
                range: start.upperBound..<source.endIndex
            )?.lowerBound ?? source.endIndex
        )
        return source.range(
            of: "recoverInboundRemoteVideoAfterDecodeStall",
            range: searchRange
        ) != nil
    }
}
