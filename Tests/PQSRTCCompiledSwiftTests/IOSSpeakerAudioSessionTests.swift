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

        let mode = try SourceContract.sourceBody(of: "setAudioMode", in: audio)
        #expect(mode.contains("} else if mode == .voiceChat {"))
        #expect(mode.contains("try audioSession.overrideOutputAudioPort(.none)"))
        #expect(mode.contains("VoiceChat earpiece override applied"))
        #expect(!audio.contains("options.insert(.defaultToSpeaker)"))
        #expect(audio.contains("options.remove(.defaultToSpeaker)"))
        #expect(audio.contains("pinWebRTCAudioConfiguration"))
        #expect(audio.contains("RTCAudioSessionConfiguration.setWebRTC"))
        #expect(audio.contains("currentRouteHasExternalCallOutput"))
        #expect(mode.contains("Call audio using external headset"))
        #expect(mode.contains("VideoChat speaker override applied"))
        #expect(!mode.contains("if !isCurrentlyOnSpeaker {"))
        #expect(audio.contains("callAudioCategoryOptions(for: mode)"))
        #expect(!audio.contains("try audioSession.setCategory(.playAndRecord)\n            try audioSession.setMode(mode)"))
        let deactivate = try SourceContract.sourceBody(of: "deactivateAudioSession", in: audio)
        #expect(deactivate.contains("overrideOutputAudioPort(.none)"))
        #expect(deactivate.contains("options.remove(.defaultToSpeaker)"))

        let state = try source("Sources/PQSRTC/RTCSession+State.swift")
        #expect(state.contains("iOS video speaker override applied on connected"))
        #expect(state.contains("iOS voice earpiece override applied on connected"))
        #expect(state.contains("outputs.contains(.builtInReceiver)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
