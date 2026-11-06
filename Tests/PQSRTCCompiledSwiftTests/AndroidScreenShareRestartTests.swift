import Foundation
import Testing

@testable import PQSRTC

/// Android screen share must start again after a stop in the same call. libwebrtc's `addTrack`
/// fails ("Sender already exists for track", which the Java wrapper turns into
/// `IllegalStateException("C++ addTrack failed.")`) while a sender still holds the track, and it
/// never reuses a transceiver that has sent before, so a second share would open a new mid
/// beyond the audio=0/camera=1/screen=2 contract. Stop has to take the track off its sender (so
/// the stop offer withdraws the share), and start has to put the track on the screen slot's
/// sender itself. `AndroidRTCClient.swift` is `#if SKIP` and the resolver is Kotlin, so this
/// pins the source shape.
@Suite(.serialized)
struct AndroidScreenShareRestartTests {
    @Test("Android screen share start reuses the screen slot sender instead of addTrack")
    func screenShareStartPutsTrackOnScreenSlotSender() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let start = try SourceContract.sourceBody(of: "prepareScreenShareSendRecv(", in: client)
        #expect(!start.contains(".addTrack("), "restart calls addTrack with a track its sender may still hold")
        #expect(start.contains("AndroidWebRTCTrackResolver.attachScreenSender("))

        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        let attach = try kotlinBody(of: "attachScreenSender", in: native)
        #expect(attach.contains("reusableScreenSlotTransceiver(peerConnection)"))
        #expect(attach.contains(".sender.setTrack(track, false)"))
        #expect(attach.contains(".sender.setStreams(streamIds)"))
        #expect(!attach.contains("addTrack("))
    }

    @Test("Android screen share stop takes the track off its sender")
    func screenShareStopDetachesScreenSender() throws {
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let stop = try SourceContract.sourceBody(of: "stopScreenCapture(", in: client)
        #expect(!stop.contains("_isEnabled = false"), "stop leaves a disabled track on the screen sender")
        #expect(stop.contains("AndroidWebRTCTrackResolver.detachScreenSender("))

        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        let detach = try kotlinBody(of: "detachScreenSender", in: native)
        #expect(detach.contains("peerConnection.removeTrack(sender)"))
        #expect(detach.contains("sender.setStreams(emptyList())"))
    }

    private func kotlinBody(of name: String, in source: String) throws -> String {
        guard let header = source.range(of: "fun \(name)("),
              let openBrace = source[header.lowerBound...].firstIndex(of: "{") else {
            throw SourceContract.Error.missingFunction(name)
        }
        let fromHeader = source[header.lowerBound...]
        var depth = 0
        for index in fromHeader.indices[openBrace...] {
            if fromHeader[index] == "{" { depth += 1 }
            if fromHeader[index] == "}" {
                depth -= 1
                if depth == 0 { return String(fromHeader[...index]) }
            }
        }
        throw SourceContract.Error.missingFunction(name)
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
