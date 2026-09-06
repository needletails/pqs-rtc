import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidRuntimeSourceContractTests {
    @Test("installSurfaceReadyCallback removes previous callback before add")
    func installSurfaceReadyCallbackRemovesPreviousBeforeAdd() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("holder.removeCallback(previous)"))
        #expect(native.contains("installedSurfaceCallbacks"))
        #expect(native.contains("holder.addCallback(callback)"))
    }

    @Test("foreground reconcile no-ops when the call has ended")
    func reconcileVideoSurfacesAfterAppForegroundNoopsWhenEnded() throws {
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        let body = try SourceContract.sourceBody(
            of: "reconcileVideoSurfacesAfterAppForeground",
            in: controller
        )
        #expect(body.contains("isCallActiveForSurfaceUnhide()"))
    }

    @Test("coalesced attach after markCallEndedLocally is a no-op")
    func coalescedAttachAfterMarkCallEndedLocallyIsNoOp() throws {
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        let attach = try SourceContract.sourceBody(of: "performParticipantVideoAttach", in: controller)
        #expect(attach.contains("shouldRunCoalescedParticipantAttach"))
        #expect(controller.contains("func shouldRunCoalescedParticipantAttach"))
        let ended = try SourceContract.sourceBody(of: "markCallEndedLocally", in: controller)
        #expect(ended.contains("participantVideoAttachLifecycleGeneration &+= 1"))
    }

    @Test("audio cryptor factory null restores track enable")
    func holdAndroidRemoteAudioRestoresEnableWhenCryptorNull() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("if (cryptor == null)"))
        #expect(native.contains("enableAndroidRemoteAudioReceiverTrack(receiver)"))
        #expect(native.contains("finally"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
