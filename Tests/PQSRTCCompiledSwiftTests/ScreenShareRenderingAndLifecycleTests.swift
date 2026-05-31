import CoreGraphics
import Testing

@testable import PQSRTC

#if os(iOS) || os(macOS)
@Suite(.serialized)
struct ScreenShareRenderingAndLifecycleTests {
    @Test("Screen share aspect fit preserves a landscape surface in a portrait tile")
    func landscapeScreenShareFitsPortraitTile() {
        let fitted = SampleBufferViewRenderer.aspectFitSize(
            sourceSize: CGSize(width: 1920, height: 1080),
            destinationSize: CGSize(width: 600, height: 900)
        )

        #expect(fitted.width == 600)
        #expect(fitted.height == 337.5)
    }

    @Test("Screen share aspect fit preserves a portrait surface in a wide tile")
    func portraitScreenShareFitsWideTile() {
        let fitted = SampleBufferViewRenderer.aspectFitSize(
            sourceSize: CGSize(width: 1080, height: 1920),
            destinationSize: CGSize(width: 900, height: 600)
        )

        #expect(fitted.width == 337.5)
        #expect(fitted.height == 600)
    }

    @Test("A visible screen share promotes an audio call out of voice-only presentation")
    func visibleScreenSharePromotesVoiceOnlyPresentation() {
        #expect(RTCSession.shouldPresentVoiceOnlyCallChrome(
            callSupportsVideo: false,
            hasVisibleScreenShare: false
        ))
        #expect(!RTCSession.shouldPresentVoiceOnlyCallChrome(
            callSupportsVideo: false,
            hasVisibleScreenShare: true
        ))
        #expect(!RTCSession.shouldPresentVoiceOnlyCallChrome(
            callSupportsVideo: true,
            hasVisibleScreenShare: false
        ))
    }

    @Test("Late completion of an old screen capture cannot own a replacement capture")
    func staleScreenCaptureGenerationDoesNotMatchReplacement() async {
        let session = await RTCSession(
            iceServers: [],
            username: "",
            password: "",
            delegate: nil
        )

        let first = await session.beginPlatformScreenCaptureGeneration()
        let second = await session.beginPlatformScreenCaptureGeneration()

        #expect(await session.isCurrentPlatformScreenCaptureGeneration(first) == false)
        #expect(await session.isCurrentPlatformScreenCaptureGeneration(second) == true)

        await session.invalidatePlatformScreenCaptureGeneration(second)
        #expect(await session.isCurrentPlatformScreenCaptureGeneration(second) == false)

        await session.shutdown(with: nil)
    }
}
#endif
