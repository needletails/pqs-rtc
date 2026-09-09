import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU departed receiver track")
struct SfuDepartedReceiverTrackPolicyTests {
    @Test("departed camera track is disabled when its mapping is removed")
    func departedCameraTrackMustBeDisabled() {
        #expect(SfuDepartedReceiverTrackPolicy.shouldDisableDepartedSfuReceiverTrack(mappingRemoved: true))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldDisableDepartedSfuReceiverTrack(mappingRemoved: false))
    }

    @Test("unresolved fallback ignores leftover inactive transceivers and local publishers")
    func unresolvedFallbackRequiresReceivingRemoteOnlyTransceiver() {
        #expect(SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate(
            transceiverIsReceivingRemoteMedia: true,
            senderHasLocalTrack: false,
            trackIsEnabled: true
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate(
            transceiverIsReceivingRemoteMedia: false,
            senderHasLocalTrack: false,
            trackIsEnabled: true
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate(
            transceiverIsReceivingRemoteMedia: true,
            senderHasLocalTrack: true,
            trackIsEnabled: true
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate(
            transceiverIsReceivingRemoteMedia: true,
            senderHasLocalTrack: false,
            trackIsEnabled: false
        ))
    }

    @Test("reconcile must not keep a leftover PART mapping")
    func leftoverMappedReceiverIsNotKept() {
        #expect(SfuDepartedReceiverTrackPolicy.shouldKeepExistingMappedSfuReceiver(
            existingTrackIsEnded: false,
            existingTrackIsReceivingCandidate: true
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldKeepExistingMappedSfuReceiver(
            existingTrackIsEnded: true,
            existingTrackIsReceivingCandidate: true
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldKeepExistingMappedSfuReceiver(
            existingTrackIsEnded: false,
            existingTrackIsReceivingCandidate: false
        ))
    }

    @Test("setRemoteSDP disables leftover enabled tracks on inactive m-lines")
    func remoteSdpDisablesLeftoverEnabledInactiveTrack() {
        #expect(SfuDepartedReceiverTrackPolicy.shouldDisableLeftoverSfuReceiverTrackAfterRemoteSDP(
            transceiverIsReceivingRemoteMedia: false,
            trackIsEnabled: true,
            isReservedScreenContractTransceiver: false
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldDisableLeftoverSfuReceiverTrackAfterRemoteSDP(
            transceiverIsReceivingRemoteMedia: true,
            trackIsEnabled: true,
            isReservedScreenContractTransceiver: false
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldDisableLeftoverSfuReceiverTrackAfterRemoteSDP(
            transceiverIsReceivingRemoteMedia: false,
            trackIsEnabled: false,
            isReservedScreenContractTransceiver: false
        ))
        #expect(!SfuDepartedReceiverTrackPolicy.shouldDisableLeftoverSfuReceiverTrackAfterRemoteSDP(
            transceiverIsReceivingRemoteMedia: false,
            trackIsEnabled: true,
            isReservedScreenContractTransceiver: true
        ))
    }

    @Test("prune disables the departed camera track, not only the mapping")
    func pruneDisablesDepartedCameraTrack() throws {
        let groupCall = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        let prune = try SourceContract.sourceBody(of: "pruneRemoteMedia", in: groupCall)
        #expect(prune.contains("SfuDepartedReceiverTrackPolicy.shouldDisableDepartedSfuReceiverTrack"))
        #expect(prune.contains("remoteVideoTracksByParticipantId.removeValue"))
        #expect(prune.contains("isEnabled = false"))
        #expect(!prune.contains("Task.sleep"))
    }

    @Test("unresolved video fallback skips non-receiving leftover transceivers")
    func unresolvedVideoFallbackFiltersInactiveLeftovers() throws {
        let handler = try source("Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift")
        let unresolved = try SourceContract.sourceBody(
            of: "mapSingleUnresolvedGroupReceiverIfNeeded",
            in: handler
        )
        #expect(unresolved.contains("SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate"))
        #expect(unresolved.contains("isAppleTransceiverReceivingRemoteMedia"))
        #expect(unresolved.contains("sender.track == nil"))
        #expect(unresolved.contains("senderHasLocalTrack"))
        #expect(unresolved.contains("trackIsEnabled"))
        #expect(!unresolved.contains("Task.sleep"))
    }

    @Test("camera reconcile skips leftover mappings and claims a live receiver")
    func cameraReconcileSkipsLeftoverMappings() throws {
        let handler = try source("Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift")
        let reconcile = try SourceContract.sourceBody(
            of: "reconcileAppleRemoteParticipantCameraTracksAfterSetRemoteSDP",
            in: handler
        )
        #expect(reconcile.contains("SfuDepartedReceiverTrackPolicy.shouldKeepExistingMappedSfuReceiver"))
        #expect(reconcile.contains("SfuDepartedReceiverTrackPolicy.shouldIncludeUnresolvedSfuReceiverCandidate"))
        #expect(reconcile.contains("trackIsEnabled"))
        #expect(reconcile.contains("emitSfuGroupMediaReadyAfterReceivingMappingUpgradeIfNeeded"))
        #expect(!reconcile.contains("Task.sleep"))
    }

    @Test("setRemoteSDP disables leftover tracks after the leave offer")
    func setRemoteSdpDisablesLeftoverTracks() throws {
        let sdpHelpers = try source("Sources/PQSRTC/RTCSession+SDPHelpers.swift")
        let setRemote = try SourceContract.sourceBody(of: "setRemoteSDP", in: sdpHelpers)
        #expect(setRemote.contains("disableLeftoverAppleSfuReceiverTracksAfterRemoteSDP"))
        #expect(!setRemote.contains("Task.sleep"))
    }

    @Test("leftover disable skips the reserved screen-share contract mid")
    func leftoverDisableSkipsReservedScreenContract() throws {
        let handler = try source("Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift")
        let disable = try SourceContract.sourceBody(
            of: "disableLeftoverAppleSfuReceiverTracksAfterRemoteSDP",
            in: handler
        )
        #expect(disable.contains("isReservedScreenContractTransceiver"))
        #expect(disable.contains("ScreenShareGroupCallContract.MediaMid.screen"))
        #expect(!disable.contains("Task.sleep"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
