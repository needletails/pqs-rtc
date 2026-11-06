import Foundation
import Testing

@testable import PQSRTC

/// Android camera and screen capture start on a detached task and open the device with the
/// client lock released. Hangup and relay fallback call `resetPeerConnectionForRetry()`, which
/// nils the capturer and disposes the video source. If that lands while the device opens, the
/// start must not store its capturer afterwards: the camera (or MediaProjection) would keep
/// feeding a disposed source, and the next call's start would see a capturer and never open the
/// device. `close()` has no callers, so `isClosed` alone never catches this. A start that is no
/// longer current (its source was replaced, or another capturer was stored) has to stop what it
/// opened. `AndroidRTCClient.swift` is `#if SKIP`, so this pins the source shape.
@Suite(.serialized)
struct AndroidCaptureStartRaceTests {
    @Test("Android camera start stops its capturer when hangup reset retired its source")
    func cameraStartStopsCapturerWhenSourceRetired() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let body = try SourceContract.sourceBody(of: "startLocalVideo(", in: client)
        let opened = try #require(body.range(of: "\"No suitable video format found\""))
        let store = String(body[opened.upperBound...])

        // `self.`: the body's `guard let videoSource = videoSource` shadows the property, so a bare
        // `videoSource` compares the snapshot with itself (Skip emits it as `videoSource_0`).
        #expect(
            store.contains("self.videoSource?.platformSource !== existingVideoSource.platformSource"),
            "the final store checks only isClosed, which no hangup path sets"
        )
        let stop = try #require(store.range(of: "capturer.stopCapture()"), "a superseded start leaves its camera running")
        let dispose = try #require(store.range(of: "helper.dispose()"))
        #expect(stop.lowerBound < dispose.lowerBound, "the helper must outlive the capturer that uses it")
    }

    @Test("Android screen capture start stops its capturer when hangup reset retired its source")
    func screenStartStopsCapturerWhenSourceRetired() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let body = try SourceContract.sourceBody(of: "startScreenCapture(", in: client)
        let opened = try #require(body.range(of: "capturer.startCapture(width, height, fps)"))
        let store = String(body[opened.upperBound...])

        #expect(
            store.contains("screenVideoSource?.platformSource !== existingSource.platformSource"),
            "the final store checks only isClosed, which no hangup path sets"
        )
        let stop = try #require(store.range(of: "capturer.stopCapture()"), "a superseded start leaves MediaProjection capturing")
        let dispose = try #require(store.range(of: "helper.dispose()"))
        #expect(stop.lowerBound < dispose.lowerBound, "the helper must outlive the capturer that uses it")
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
