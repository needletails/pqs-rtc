import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct IceReconnectCameraTileSettlementPolicyTests {
    @Test("ICE reconnect after disconnect settles mapped group camera tiles")
    func reconnectAfterDisconnectSettlesMappedGroupTiles() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            )
        )
    }

    @Test("ICE reconnect after failed settles mapped group camera tiles")
    func reconnectAfterFailedSettlesMappedGroupTiles() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "completed",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            )
        )
    }

    @Test("join-path checking to connected does not settle camera tiles")
    func joinPathCheckingToConnectedDoesNotSettle() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: false,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            ) == false
        )
    }

    @Test("ICE reconnect does not settle 1:1 or unmapped rooms")
    func reconnectDoesNotSettleOneToOneOrUnmappedRooms() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: true,
                isGroupOrConference: false,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            ) == false
        )
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: false,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            ) == false
        )
    }

    @Test("ICE reconnect defers to in-flight SFU renegotiation and relay fallback")
    func reconnectDefersToRenegotiationAndRelayFallback() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: true,
                relayFallbackRetrying: false
            ) == false
        )
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "connected",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: true
            ) == false
        )
    }

    @Test("only recovered ICE states settle after a media-path disruption")
    func onlyRecoveredIceStatesSettle() {
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathDisruption("disconnected"))
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathDisruption("failed"))
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathDisruption("checking") == false)
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathRecovered("connected"))
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathRecovered("completed"))
        #expect(IceReconnectCameraTileSettlementPolicy.isIceMediaPathRecovered("checking") == false)
        #expect(
            IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles(
                newIceState: "checking",
                hadMediaPathDisruption: true,
                isGroupOrConference: true,
                hasMappedRemoteCameraParticipants: true,
                renegotiationInFlight: false,
                relayFallbackRetrying: false
            ) == false
        )
    }

    @Test("ICE reconnect refreshes every mapped camera participant")
    func iceReconnectRefreshesEveryMappedCameraParticipant() {
        #expect(
            IceReconnectCameraTileSettlementPolicy.participantIdsNeedingIceReconnectTileRefresh(
                allMappedParticipantIds: ["sdx26", "", " mm26 ", "sdx26"]
            ) == ["mm26", "sdx26"]
        )
        #expect(
            IceReconnectCameraTileSettlementPolicy.participantIdsNeedingIceReconnectTileRefresh(
                allMappedParticipantIds: []
            ).isEmpty
        )
    }

    @Test("ICE handlers settle camera tiles on reconnect without decode-stall recovery")
    func iceHandlersUseReconnectSettlementNotDecodeStallRecovery() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let handler = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift"
            ),
            encoding: .utf8
        )
        let video = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Video.swift"
            ),
            encoding: .utf8
        )
        #expect(handler.contains("noteIceConnectionStateAndSettleRemoteCameraTilesIfNeeded"))
        #expect(handler.contains("IceReconnectCameraTileSettlementPolicy.shouldSettleRemoteCameraTiles"))
        #expect(video.contains("settleGroupRemoteCameraTilesAfterIceReconnectIfNeeded"))
        #expect(video.contains("forceParticipantSinkRefreshWhenTrackIdentityMatches: true"))
        #expect(video.contains("queueParticipantCameraRendererSinkRefresh"))
        #expect(video.contains("emitRemoteParticipantTrackRefreshAfterSfuRenegotiation"))
        #expect(!iceConnectedHandlerCallsDecodeStallRecovery(handler))
    }

    private func iceConnectedHandlerCallsDecodeStallRecovery(_ handler: String) -> Bool {
        handler.range(
            of: "recoverInboundRemoteVideoAfterDecodeStall",
            range: handler.range(of: "case .iceConnectionStateDidChange")
                .flatMap { start in
                    handler.range(of: "case .generatedIceCandidate", range: start.lowerBound..<handler.endIndex)
                        .map { start.lowerBound..<$0.lowerBound }
                } ?? handler.startIndex..<handler.endIndex
        ) != nil
            || handler.range(
                of: "recoverInboundRemoteVideoAfterDecodeStall",
                range: handler.range(of: "case .standardizedIceConnectionState")
                    .flatMap { start in start.lowerBound..<handler.endIndex }
            ) != nil
    }
}
