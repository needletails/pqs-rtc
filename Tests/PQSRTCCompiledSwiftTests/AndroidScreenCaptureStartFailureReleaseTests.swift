import Foundation
import Testing

@testable import PQSRTC

/// Android screen capture start opens three things before it stores anything: the media-projection
/// foreground service, a `SurfaceTextureHelper` (a handler thread plus an EGL context) and the
/// `ScreenCapturerAndroid`, whose `startCapture` takes the MediaProjection. A start that throws
/// after that (no consent intent left to consume, or the SecurityException MediaProjection raises
/// on API 34+) never reaches the store, so nothing later can release them: `stopScreenCapture`
/// only sees stored state. And the service returns START_STICKY, so after process death Android
/// restarts it into `startForeground(MEDIA_PROJECTION)` with no projection behind it.
/// Both files are `#if SKIP`, so this pins the source shape.
@Suite(.serialized)
struct AndroidScreenCaptureStartFailureReleaseTests {
    @Test("Android screen capture start releases what it opened when it fails")
    func screenStartFailureReleasesWhatItOpened() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let body = code(try SourceContract.sourceBody(of: "startScreenCapture(", in: client))
        let service = try #require(body.range(of: "AndroidScreenCaptureForeground.startAndAwaitReady("))
        let start = try #require(body.range(of: "capturer.startCapture(width, height, fps)"))
        let opened = String(body[service.lowerBound..<start.lowerBound])

        #expect(
            !opened.contains("AndroidMediaProjectionResultHolder.consume()"),
            "a missing consent intent is found after the service and helper are up, and that throw releases neither"
        )
        #expect(
            occurrences(of: "throw ", in: opened) == occurrences(of: "AndroidScreenCaptureForeground.stopIfRunning()", in: opened),
            "a throw after the foreground service starts leaves it running"
        )

        let tail = String(body[start.upperBound...])
        let caught = try #require(tail.range(of: "} catch {"), "a failed startCapture leaks the helper thread, its EGL context and the projection")
        let stop = try #require(tail.range(of: "capturer.stopCapture()"))
        let dispose = try #require(tail.range(of: "helper.dispose()"))
        #expect(caught.lowerBound < stop.lowerBound && stop.lowerBound < dispose.lowerBound)
        #expect(tail.contains("peerConnectionError(startFailure ??"), "the release tail must report the startCapture failure")
    }

    @Test("Android screen capture service is not restarted after process death")
    func screenCaptureServiceIsNotSticky() throws {
        let service = try source("Sources/PQSRTC/Android/AndroidScreenCaptureService.swift")
        let body = try SourceContract.sourceBody(of: "onStartCommand(", in: service)

        #expect(
            !body.contains("Service.START_STICKY"),
            "a restarted service calls startForeground(MEDIA_PROJECTION) with no projection"
        )
        #expect(body.contains("android.app.Service.START_NOT_STICKY"))
    }

    /// The function's statements: Swift lines and `SKIP INSERT` Kotlin, without other comments.
    private func code(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let insert = trimmed.range(of: "// SKIP INSERT:"), insert.lowerBound == trimmed.startIndex {
                return String(trimmed[insert.upperBound...])
            }
            return trimmed.hasPrefix("//") ? nil : String(line)
        }.joined(separator: "\n")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
