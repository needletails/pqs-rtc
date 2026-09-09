import Foundation
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

extension RTCSession {
    func essentialOutboundInFlightCount(for connectionId: String) -> Int {
        essentialOutboundInFlightCountByConnectionId[connectionId.normalizedConnectionId] ?? 0
    }

    func noteEssentialOutbound(
        _ event: SfuSignalingUplinkYieldPolicy.Event,
        connectionId: String
    ) async {
        let connKey = connectionId.normalizedConnectionId
        let call = await connectionManager.findConnection(with: connKey)?.call
        guard isGroupOrConferenceSignalingLane(connectionId: connKey, call: call) else { return }
        let previous = essentialOutboundInFlightCount(for: connKey)
        let next = SfuSignalingUplinkYieldPolicy.nextEssentialInFlightCount(
            current: previous,
            event: event
        )
        if next == 0 {
            essentialOutboundInFlightCountByConnectionId.removeValue(forKey: connKey)
        } else {
            essentialOutboundInFlightCountByConnectionId[connKey] = next
        }
        guard SfuSignalingUplinkYieldPolicy.shouldApplyImmediately(
            previousCount: previous,
            newCount: next
        ) else { return }
        await applySfuUplinkYieldTargets(connectionId: connKey)
    }

    func isGroupOrConferenceSignalingLane(connectionId: String, call: Call? = nil) -> Bool {
        let connKey = connectionId.normalizedConnectionId
        let looksGroup = isGroupCallConnection(connKey)
            || call?.sharedCommunicationId.isGroupCall == true
            || connKey.isGroupCall
        guard looksGroup else { return false }
        if let call { return !Self.isTrueOneToOneSfuRoom(call: call) }
        return true
    }

    func applySfuUplinkYieldTargets(connectionId: String) async {
        let connKey = connectionId.normalizedConnectionId
        guard let connection = await connectionManager.findConnection(with: connKey) else { return }
        guard connection.call.supportsVideo else { return }
        let cfg = sfuAdaptiveConfig(for: connection.call)
        let targets = RTCAdaptiveVideoTargets.survivalTargets(cfg: cfg)
        applyVideoSenderTargets(targets, connection: connection)
#if os(Android) || canImport(WebRTC)
        adaptiveVideoLastAppliedByConnectionId[connKey] = (
            bitrateBps: targets.maxBitrateBps,
            framerate: targets.maxFramerate,
            scaleResolutionDownBy: targets.scaleResolutionDownBy
        )
#endif
    }

    func applyVideoSenderTargets(_ targets: AdaptiveVideoTargets, connection: RTCConnection) {
#if os(Android)
        rtcClient.setVideoSenderEncodings(
            maxBitrateBps: targets.maxBitrateBps,
            maxFramerate: targets.maxFramerate,
            scaleResolutionDownBy: targets.scaleResolutionDownBy
        )
#elseif canImport(WebRTC)
        for sender in connection.peerConnection.senders where sender.track?.kind == kRTCMediaStreamTrackKindVideo {
            var params = sender.parameters
            guard !params.encodings.isEmpty else { continue }
            for encoding in params.encodings {
                encoding.maxBitrateBps = NSNumber(value: targets.maxBitrateBps)
                encoding.maxFramerate = NSNumber(value: targets.maxFramerate)
                encoding.scaleResolutionDownBy = NSNumber(value: targets.scaleResolutionDownBy)
            }
            sender.parameters = params
        }
#else
        _ = targets
        _ = connection
#endif
    }
}
