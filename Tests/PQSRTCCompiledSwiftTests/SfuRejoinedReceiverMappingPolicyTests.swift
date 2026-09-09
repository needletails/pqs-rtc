import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU rejoined receiver mapping")
struct SfuRejoinedReceiverMappingPolicyTests {
    @Test("leftover-to-live mapping upgrade emits a fresh mediaReady generation")
    func leftoverToLiveUpgradeEmits() {
        #expect(SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: false,
            newTrackIsReceiving: true,
            previousTrackId: "video_nudge_leftover",
            newTrackId: "c33aaf56-live"
        ))
    }

    @Test("first-join attach without a previous track must not encrypt another mediaReady")
    func firstJoinDoesNotEmit() {
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: false,
            newTrackIsReceiving: true,
            previousTrackId: nil,
            newTrackId: "c33aaf56-live"
        ))
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: false,
            newTrackIsReceiving: true,
            previousTrackId: "",
            newTrackId: "c33aaf56-live"
        ))
    }

    @Test("same-track or already-receiving mappings do not emit")
    func sameTrackOrAlreadyReceivingDoesNotEmit() {
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: false,
            newTrackIsReceiving: true,
            previousTrackId: "video_nudge_leftover",
            newTrackId: "video_nudge_leftover"
        ))
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: true,
            newTrackIsReceiving: true,
            previousTrackId: "old",
            newTrackId: "new"
        ))
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade(
            previousTrackIsReceiving: false,
            newTrackIsReceiving: false,
            previousTrackId: "old",
            newTrackId: "new"
        ))
    }

    @Test("PART prune resets the mediaReady generation")
    func pruneResetsGeneration() {
        #expect(SfuRejoinedReceiverMappingPolicy.shouldResetMediaReadyGenerationAfterDepartedMappingRemoved(
            mappingRemoved: true
        ))
        #expect(!SfuRejoinedReceiverMappingPolicy.shouldResetMediaReadyGenerationAfterDepartedMappingRemoved(
            mappingRemoved: false
        ))
    }

    @Test("prune and leftover-to-live mapping start a new mediaReady generation")
    func pruneAndUpgradeAreWired() throws {
        let groupCall = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        let prune = try SourceContract.sourceBody(of: "pruneRemoteMedia", in: groupCall)
        let emit = try SourceContract.sourceBody(
            of: "emitSfuGroupMediaReadyAfterReceivingMappingUpgradeIfNeeded",
            in: groupCall
        )
        #expect(prune.contains("SfuRejoinedReceiverMappingPolicy.shouldResetMediaReadyGenerationAfterDepartedMappingRemoved"))
        #expect(prune.contains("resetSfuGroupMediaReadyGeneration"))
        #expect(emit.contains("SfuRejoinedReceiverMappingPolicy.shouldEmitMediaReadyAfterReceivingMappingUpgrade"))
        #expect(emit.contains("resetSfuGroupMediaReadyGeneration"))
        #expect(emit.contains("sendSfuGroupMediaReady"))
        #expect(!prune.contains("Task.sleep"))
        #expect(!emit.contains("Task.sleep"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
