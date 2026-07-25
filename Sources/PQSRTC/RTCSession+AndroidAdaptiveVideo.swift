//
//  RTCSession+AndroidAdaptiveVideo.swift
//  pqs-rtc
//
//  Adaptive SFU video sender caps for Android.
//

#if os(Android)
import Foundation

extension RTCSession {
    func startAdaptiveVideoSendIfNeeded(connectionId: String) async {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }

        if let existing = adaptiveVideoSendTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        guard let connection = await connectionManager.findConnection(with: normalizedId) else { return }
        guard connection.id.isGroupCall else { return }
        guard connection.call.supportsVideo else { return }

        logger.log(level: .info, message: "Starting adaptive video send loop (Android) for connectionId=\(normalizedId)")

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let current = await self.connectionManager.findConnection(with: normalizedId) else { break }
                guard current.id.isGroupCall else { break }
                if !current.call.supportsVideo { break }

                let isOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: current.call)
                let cfg = await self.sfuAdaptiveConfig(for: current.call)

                let network = await self.rtcClient.getAdaptiveNetworkStats()
                let previousInbound = await self.adaptiveInboundVideoRtpTotals(for: normalizedId)
                let inboundLoss = await self.updateAdaptiveInboundVideoLossFraction(
                    connectionId: normalizedId,
                    packetsReceived: network.inboundVideoPacketsReceived,
                    packetsLost: network.inboundVideoPacketsLost,
                    previous: previousInbound
                )

                let targets: AdaptiveVideoTargets
                if let available = network.availableOutgoingBitrateBps, available > 0 {
                    targets = RTCAdaptiveVideoTargets.compute(
                        cfg: cfg,
                        isOneToOneSfu: isOneToOneSfu,
                        reportedAvailableOutgoingBps: available,
                        currentRttSeconds: network.currentRttSeconds,
                        availableIncomingBitrateBps: network.availableIncomingBitrateBps,
                        inboundVideoLossFraction: inboundLoss
                    )
                } else {
                    targets = RTCAdaptiveVideoTargets.conservativeStartupTargets(
                        cfg: cfg,
                        isOneToOneSfu: isOneToOneSfu
                    )
                }

                let lastApplied = await self.adaptiveVideoLastAppliedByConnectionId[normalizedId]
                let deltaOk = RTCAdaptiveVideoTargets.shouldApply(targets, lastApplied: lastApplied)

                if deltaOk {
                    self.rtcClient.setVideoSenderEncodings(
                        maxBitrateBps: targets.maxBitrateBps,
                        maxFramerate: targets.maxFramerate,
                        scaleResolutionDownBy: targets.scaleResolutionDownBy
                    )
                    await self.setAdaptiveVideoLastApplied(
                        connectionId: normalizedId,
                        bitrateBps: targets.maxBitrateBps,
                        framerate: targets.maxFramerate,
                        scaleResolutionDownBy: targets.scaleResolutionDownBy
                    )
                    self.logger.log(
                        level: .debug,
                        message: "Adaptive video send applied (Android, connId=\(normalizedId) oneToOne=\(isOneToOneSfu)): maxBitrateBps=\(targets.maxBitrateBps) maxFramerate=\(targets.maxFramerate) scaleResolutionDownBy=\(targets.scaleResolutionDownBy) reportedAvailableBps=\(network.availableOutgoingBitrateBps.map { String(Int($0)) } ?? "nil") rttMs=\(network.currentRttSeconds.map { String(Int($0 * 1000)) } ?? "nil") inboundLoss=\(inboundLoss.map { String(format: "%.2f", $0) } ?? "nil")"
                    )
                }

                let quality: RTCNetworkQuality
                if let available = network.availableOutgoingBitrateBps {
                    if available < 150_000 {
                        quality = .veryPoor
                    } else if available < 300_000 {
                        quality = .poor
                    } else if available < 700_000 {
                        quality = .fair
                    } else if available < 1_500_000 {
                        quality = .good
                    } else {
                        quality = .excellent
                    }
                } else {
                    quality = .poor
                }

                await self.emitNetworkQualityUpdateIfNeeded(
                    connectionId: normalizedId,
                    quality: quality,
                    availableOutgoingBitrateBps: network.availableOutgoingBitrateBps.map { Int($0) },
                    availableIncomingBitrateBps: network.availableIncomingBitrateBps.map { Int($0) },
                    rttMs: network.currentRttSeconds.map { Int($0 * 1000.0) },
                    appliedVideoMaxBitrateBps: targets.maxBitrateBps,
                    appliedVideoMaxFramerate: targets.maxFramerate,
                    nowUptimeNs: DispatchTime.now().uptimeNanoseconds
                )

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        adaptiveVideoSendTasksByConnectionId[normalizedId] = task
    }

    func stopAdaptiveVideoSend(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let task = adaptiveVideoSendTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
        adaptiveVideoLastAppliedByConnectionId.removeValue(forKey: normalizedId)
        adaptiveInboundVideoRtpTotalsByConnectionId.removeValue(forKey: normalizedId)
    }

    private func setAdaptiveVideoLastApplied(connectionId: String, bitrateBps: Int, framerate: Int, scaleResolutionDownBy: Double) {
        adaptiveVideoLastAppliedByConnectionId[connectionId] = (bitrateBps, framerate, scaleResolutionDownBy)
    }

    private func adaptiveInboundVideoRtpTotals(
        for connectionId: String
    ) -> (packetsReceived: Int64, packetsLost: Int64)? {
        adaptiveInboundVideoRtpTotalsByConnectionId[connectionId]
    }

    private func updateAdaptiveInboundVideoLossFraction(
        connectionId: String,
        packetsReceived: Int64,
        packetsLost: Int64,
        previous: (packetsReceived: Int64, packetsLost: Int64)?
    ) -> Double? {
        adaptiveInboundVideoRtpTotalsByConnectionId[connectionId] = (
            packetsReceived: packetsReceived,
            packetsLost: packetsLost
        )
        guard let previous else { return nil }
        let deltaReceived = max(Int64(0), packetsReceived - previous.packetsReceived)
        let deltaLost = max(Int64(0), packetsLost - previous.packetsLost)
        let denom = deltaReceived + deltaLost
        guard denom > 0 else { return nil }
        return Double(deltaLost) / Double(denom)
    }
}
#endif
