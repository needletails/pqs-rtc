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

        // Idempotent: only one loop per connection.
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

                let cfg = await self.sfuVideoQualityProfile.adaptiveConfig

                // Query available outgoing bitrate via Android WebRTC stats.
                let available = await self.rtcClient.getAvailableOutgoingBitrateBps()
                guard let available, available > 0 else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                let rawTarget = Int(available * cfg.headroomFactor)
                let targetBps = max(cfg.minBitrateBps, min(cfg.maxBitrateBps, rawTarget))
                let targetFps: Int = (targetBps >= cfg.highFpsThresholdBps) ? cfg.highFps : cfg.lowFps

                let last = await self.adaptiveVideoLastAppliedByConnectionId[normalizedId]
                let lastBps = last?.bitrateBps ?? 0
                let lastFps = last?.framerate ?? 0
                let deltaOk: Bool
                if lastBps == 0 {
                    deltaOk = true
                } else {
                    let ratio = Double(abs(targetBps - lastBps)) / Double(max(1, lastBps))
                    deltaOk = ratio >= 0.15 || targetFps != lastFps
                }

                if deltaOk {
                    self.rtcClient.setVideoSenderEncodings(maxBitrateBps: targetBps, maxFramerate: targetFps)
                    await self.setAdaptiveVideoLastApplied(connectionId: normalizedId, bitrateBps: targetBps, framerate: targetFps)
                    self.logger.log(level: .debug, message: "Adaptive video send applied (Android, connId=\(normalizedId)): maxBitrateBps=\(targetBps) maxFramerate=\(targetFps) (availableOutgoingBitrate=\(Int(available)))")
                }

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
    }

    private func setAdaptiveVideoLastApplied(connectionId: String, bitrateBps: Int, framerate: Int) {
        adaptiveVideoLastAppliedByConnectionId[connectionId] = (bitrateBps, framerate)
    }
}
#endif

