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
