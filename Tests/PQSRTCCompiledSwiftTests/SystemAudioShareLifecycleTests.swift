import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct SystemAudioShareLifecycleTests {
    @Test("begin share muted then user unmute clears suppression")
    func beginShareMutedThenUnmuteClearsSuppressMicCapture() {
        #expect(
            SystemAudioShareMicPolicy.suppressionForAudioIntent(
                shareIsActive: true,
                audioTrackRequestedEnabled: true,
                isMixerForcedTrackEnable: false
            ) == false
        )
    }

    @Test("mixer-forced track enable preserves start-muted suppression")
    func beginShareMutedKeepsTrackEnabledButMicSuppressed() {
        #expect(
            SystemAudioShareMicPolicy.suppressionForAudioIntent(
                shareIsActive: true,
                audioTrackRequestedEnabled: true,
                isMixerForcedTrackEnable: true
            ) == nil
        )
    }

    @Test("call-end media release tears down system-audio egress")
    func finishEndConnectionWithoutRemoveScreenTrackClearsSystemAudioEgress() throws {
        let audio = try source("Sources/PQSRTC/RTCSession+Audio.swift")
        let setAudio = try sourceBody(of: "setAudioTrack", in: audio)
        #expect(setAudio.contains("updateSystemAudioShareMicSuppressionForAudioIntent"))

        let screen = try source("Sources/PQSRTC/RTCSession+ScreenShare.swift")
        let begin = try sourceBody(of: "beginSystemAudioShareEgress", in: screen)
        #expect(begin.contains("updateSystemAudioMicSuppression: false"))

        let peer = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        let release = try sourceBody(of: "releaseLocalMediaResourcesForCallEnding", in: peer)
        #expect(release.contains("endSystemAudioShareEgressIfNeeded"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func sourceBody(of functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let start = source.range(of: marker) else {
            throw SourceGuardError.missingFunction(functionName)
        }
        let suffix = source[start.lowerBound...]
        guard let openingBrace = suffix.firstIndex(of: "{") else {
            throw SourceGuardError.missingFunction(functionName)
        }
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(suffix[...index]) }
            default: break
            }
        }
        throw SourceGuardError.missingFunction(functionName)
    }

    private enum SourceGuardError: Error {
        case missingFunction(String)
    }
}
