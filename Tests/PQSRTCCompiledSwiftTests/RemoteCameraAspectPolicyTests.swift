import Testing
@testable import PQSRTC

@Suite
struct RemoteCameraAspectPolicyTests {
    @Test("Grid force-fit always letterboxes")
    func forceFitAlwaysLetterboxes() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: true,
                fillWhenOrientationMatches: true,
                remoteWidth: 1920,
                remoteHeight: 1080,
                localWidth: 1920,
                localHeight: 1080
            ) == true
        )
    }

    @Test("Matching portrait orientations fill")
    func matchingPortraitFills() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                remoteWidth: 1080,
                remoteHeight: 1920,
                localWidth: 390,
                localHeight: 844
            ) == false
        )
    }

    @Test("Matching landscape orientations fill")
    func matchingLandscapeFills() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                remoteWidth: 1920,
                remoteHeight: 1080,
                localWidth: 844,
                localHeight: 390
            ) == false
        )
    }

    @Test("Portrait remote on landscape local letterboxes")
    func mismatchedOrientationsLetterbox() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                remoteWidth: 1080,
                remoteHeight: 1920,
                localWidth: 844,
                localHeight: 390
            ) == true
        )
    }

    @Test("Unknown remote size letterboxes while match-fill is enabled")
    func unknownRemoteLetterboxes() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                remoteWidth: 0,
                remoteHeight: 0,
                localWidth: 390,
                localHeight: 844
            ) == true
        )
    }

    @Test("Legacy always-fill ignores orientation mismatch")
    func legacyAlwaysFill() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: false,
                remoteWidth: 1080,
                remoteHeight: 1920,
                localWidth: 844,
                localHeight: 390
            ) == false
        )
    }

    @Test("Screen-share strip match-fills when the item matches the remote")
    func screenShareStripMatchFillsMatchingItem() {
        let forceFit = RemoteCameraAspectPolicy.forceFitForCameraTiles(
            cameraTileCount: 1,
            hasVisibleScreenShare: true
        )
        let matchFill = RemoteCameraAspectPolicy.fillWhenOrientationMatchesForCameraTiles(
            cameraTileCount: 1,
            hasVisibleScreenShare: true
        )
        #expect(forceFit == false)
        #expect(matchFill == true)
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: forceFit,
                fillWhenOrientationMatches: matchFill,
                remoteWidth: 1920,
                remoteHeight: 1080,
                localWidth: 360,
                localHeight: 202
            ) == false,
            "landscape remote in a 16:9 item must fill end to end"
        )
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: forceFit,
                fillWhenOrientationMatches: matchFill,
                remoteWidth: 1080,
                remoteHeight: 1920,
                localWidth: 360,
                localHeight: 202
            ) == true,
            "portrait remote in a 16:9 item must letterbox"
        )
    }

    @Test("Solo camera without a share uses match-fill")
    func soloCameraWithoutShareUsesMatchFill() {
        #expect(
            RemoteCameraAspectPolicy.forceFitForCameraTiles(
                cameraTileCount: 1,
                hasVisibleScreenShare: false
            ) == false
        )
        #expect(
            RemoteCameraAspectPolicy.fillWhenOrientationMatchesForCameraTiles(
                cameraTileCount: 1,
                hasVisibleScreenShare: false
            ) == true
        )
    }

    @Test("Multi-camera grid force-fits even without a share")
    func multiCameraGridForceFitsWithoutShare() {
        #expect(
            RemoteCameraAspectPolicy.forceFitForCameraTiles(
                cameraTileCount: 2,
                hasVisibleScreenShare: false
            ) == true
        )
        #expect(
            RemoteCameraAspectPolicy.fillWhenOrientationMatchesForCameraTiles(
                cameraTileCount: 2,
                hasVisibleScreenShare: false
            ) == false
        )
    }

    @Test("Landscape buffer with 90° rotation letterboxes in a landscape strip cell")
    func rotatedLandscapeBufferLetterboxesInLandscapeStrip() {
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: true,
                fillWhenOrientationMatches: false,
                sourceWidth: 1920,
                sourceHeight: 1080,
                rotationDegrees: 90,
                destinationWidth: 320,
                destinationHeight: 180
            ) == true
        )
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                sourceWidth: 1920,
                sourceHeight: 1080,
                rotationDegrees: 90,
                destinationWidth: 320,
                destinationHeight: 180
            ) == true
        )
        #expect(
            RemoteCameraAspectPolicy.prefersAspectFit(
                forceFit: false,
                fillWhenOrientationMatches: true,
                sourceWidth: 1920,
                sourceHeight: 1080,
                rotationDegrees: 0,
                destinationWidth: 320,
                destinationHeight: 180
            ) == false
        )
    }

    @Test("Portrait texture letterboxes inside a landscape drawable instead of stretching")
    func portraitTextureLetterboxesInLandscapeDrawable() {
        let fitted = RemoteCameraAspectPolicy.letterboxedRect(
            sourceWidth: 390,
            sourceHeight: 700,
            destinationWidth: 960,
            destinationHeight: 540
        )
        #expect(abs(fitted.width / fitted.height - 390.0 / 700.0) < 0.001)
        #expect(fitted.height == 540)
        #expect(fitted.x > 0)
        #expect(abs(fitted.y) < 0.001)
        #expect(fitted.x + fitted.width < 960)

        let matched = RemoteCameraAspectPolicy.letterboxedRect(
            sourceWidth: 320,
            sourceHeight: 180,
            destinationWidth: 960,
            destinationHeight: 540
        )
        #expect(abs(matched.x) < 0.001)
        #expect(abs(matched.y) < 0.001)
        #expect(abs(matched.width - 960) < 0.001)
        #expect(abs(matched.height - 540) < 0.001)
    }

    @Test("Upright dimensions swap on 90 and 270")
    func uprightDimensionsSwapOnQuarterTurns() {
        let swapped90 = RemoteCameraAspectPolicy.uprightDimensions(width: 1920, height: 1080, rotationDegrees: 90)
        #expect(swapped90.width == 1080)
        #expect(swapped90.height == 1920)
        let swapped270 = RemoteCameraAspectPolicy.uprightDimensions(width: 1280, height: 720, rotationDegrees: 270)
        #expect(swapped270.width == 720)
        #expect(swapped270.height == 1280)
        let upright = RemoteCameraAspectPolicy.uprightDimensions(width: 1280, height: 720, rotationDegrees: 0)
        #expect(upright.width == 1280)
        #expect(upright.height == 720)
    }
}
