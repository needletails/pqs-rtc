import Foundation
import Testing

/// iOS/Android defer a share's offer until ReplayKit/MediaProjection reports capture-ready and arm a
/// 60 s rollback timer. Call teardown (finishEndConnection, shutdown) cancels neither that timer nor the
/// pending id, so when the picker is cancelled and the call ends, the timer still fires later. Rolling
/// back then stops whatever capture is current, possibly a later call's share, and reports
/// isSharing=false. The timer must only roll back a share whose track is still on its connection.
@Suite("Abandoned screen-share timer after call end")
struct AbandonedShareTimerAfterCallEndTests {
    /// The timer is iOS/Android only and does not compile on macOS, so this is a source contract.
    @Test
    func timeoutRollsBackOnlyAShareStillOnItsConnection() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+ScreenShare.swift"),
            encoding: .utf8
        )
        let body = try SourceContract.sourceBody(of: "handleAbandonedScreenShareCaptureTimeout", in: source)
        let liveCheck = try #require(body.range(
            of: "await connectionManager.findConnection(with: connectionId)?.localScreenTrack != nil"))
        let staleGuard = try #require(body.range(of: "guard shareIsOnConnection else {"))
        let rollback = try #require(body.range(of: "await removeScreenTrackFromStream(connectionId: connectionId)"))
        #expect(liveCheck.upperBound < staleGuard.lowerBound)
        #expect(staleGuard.upperBound < rollback.lowerBound)
    }
}
