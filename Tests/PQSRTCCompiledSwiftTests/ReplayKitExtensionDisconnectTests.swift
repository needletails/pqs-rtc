import Foundation
import Testing

@testable import PQSRTC

/// `iOSScreenCaptureSource` is iOS-only and needs the app-group container, so it cannot run
/// in the macOS harness; this is a source contract.
///
/// The broadcast extension can die without sending `.finished` (a crash, or a jetsam kill at
/// the 50 MB extension memory limit). The kernel then closes its socket and the receiver's
/// read hits EOF. That has to end the share like `.finished` does. If it only goes back to
/// `accept`, nothing reconnects, and the screen track, sender and SDP stay advertised while
/// the UI stays on "sharing" and remotes see a frozen frame.
@Suite(.serialized)
struct ReplayKitExtensionDisconnectTests {
    @Test("extension disconnect without .finished ends the share")
    func extensionDisconnectWithoutFinishedEndsShare() throws {
        let receiver = try source("Sources/PQSRTC/ScreenCapture/iOSScreenCaptureSource.swift")

        // A failed read ends the broadcast while this client is still the relay's own. A
        // close from stopCapture clears isRunning first, so it does not count.
        let readLoop = compact(try SourceContract.sourceBody(of: "readLoop", in: receiver))
        let reads = readLoop.components(separatedBy: "readExactly(").count - 1
        #expect(reads == 2)
        #expect(readLoop.components(separatedBy: "else { return relayIsRunning(client: client) }").count - 1 == reads)
        // A malformed packet only drops this connection; the extension reconnects on its next write.
        #expect(readLoop.contains("packet parse failed: \\(error)\") return false"))

        // `.finished` and a disconnect go through the same single finish site.
        let acceptLoop = compact(try SourceContract.sourceBody(of: "acceptLoop", in: receiver))
        #expect(acceptLoop.contains("let broadcastEnded = readLoop(client: client)"))
        #expect(acceptLoop.contains("if broadcastEnded { deactivateSystemAudioIfNeeded() onBroadcastFinished?() }"))
        #expect(receiver.components(separatedBy: "onBroadcastFinished?()").count - 1 == 1)
    }

    private func compact(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
