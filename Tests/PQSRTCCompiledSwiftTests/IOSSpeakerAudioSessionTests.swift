import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct IOSSpeakerAudioSessionTests {
    @Test("speaker output uses locked RTCAudioSession")
    func setSpeakerOutputUsesLockedRTCAudioSession() throws {
        let uiKit = try source(
            "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift"
        )
        let speaker = try SourceContract.sourceBody(of: "setSpeakerOutputEnabled", in: uiKit)
        #expect(speaker.contains("setSpeakerOutputOverride"))
        #expect(!speaker.contains("AVAudioSession.sharedInstance()"))
        #expect(!speaker.contains("overrideOutputAudioPort"))

        let teardown = try SourceContract.sourceBody(of: "tearDownCall", in: uiKit)
        #expect(teardown.contains("setSpeakerOutputOverride(false)"))
        #expect(!teardown.contains("AVAudioSession.sharedInstance().overrideOutputAudioPort"))

        let audio = try source("Sources/PQSRTC/RTCSession+Audio.swift")
        let helper = try SourceContract.sourceBody(of: "setSpeakerOutputOverride", in: audio)
        #expect(helper.contains("lockForConfiguration()"))
        #expect(helper.contains("overrideOutputAudioPort"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
