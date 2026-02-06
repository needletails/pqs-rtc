//
//  RTCSession+Stats.swift
//  pqs-rtc
//
//  Diagnostics: outbound RTP + selected candidate pair.
//

import Foundation
import NeedleTailLogger

#if canImport(WebRTC)
import WebRTC

extension RTCSession {
    
    /// Starts a periodic WebRTC stats loop that answers:
    /// - are we sending outbound RTP at all?
    /// - which ICE candidate pair is selected?
    /// - is DTLS connected?
    ///
    /// This is gated by `PQSRTCDiagnostics.criticalBugLoggingEnabled`.
    func startOutboundRtpStatsLoggingIfEnabled(connectionId: String) async {
        guard PQSRTCDiagnostics.criticalBugLoggingEnabled else { return }
        
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        
        // Idempotent: only one loop per connection.
        if let existing = outboundRtpStatsTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }
        
        guard let connection = await connectionManager.findConnection(with: normalizedId) else {
            logger.log(level: .warning, message: "Stats logging skipped: no connection for id=\(normalizedId)")
            return
        }
        
        logger.log(level: .info, message: "Starting RTP egress stats loop for connectionId=\(normalizedId)")
        
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            
            // Run for up to ~60s unless cancelled/teardown.
            // (Enough to capture initial media start; avoid infinite background spam.)
            let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
            
            while !Task.isCancelled {
                if DispatchTime.now().uptimeNanoseconds > deadline { break }
                
                // Avoid reading stats after teardown.
                guard let current = await self.connectionManager.findConnection(with: normalizedId) else { break }
                
                let report = await self.collectStats(peerConnection: current.peerConnection)
                await self.logRtpEgressSnapshot(connectionId: normalizedId, report: report)
                
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            }
        }
        
        outboundRtpStatsTasksByConnectionId[normalizedId] = task
    }
    
    func stopOutboundRtpStatsLogging(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let task = outboundRtpStatsTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
    }
    
    // MARK: - Stats helpers
    
    private func collectStats(peerConnection: RTCPeerConnection) async -> RTCStatisticsReport {
        await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                continuation.resume(returning: report)
            }
        }
    }

    // MARK: - Adaptive video send (SFU/group calls)
    //
    // We use candidate-pair.availableOutgoingBitrate (Bps) as the primary signal and apply a
    // headroom factor so we don't ride the absolute edge of congestion control.
    //
    // This is intentionally NOT gated by diagnostics flags; it is functional behavior.
    func startAdaptiveVideoSendIfNeeded(connectionId: String) async {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }

        // Idempotent: only one loop per connection.
        if let existing = adaptiveVideoSendTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        guard let connection = await connectionManager.findConnection(with: normalizedId) else { return }
        // Only apply to SFU/group calls (our convention: id begins with "#").
        guard connection.id.isGroupCall else { return }
        // Don't run if this call isn't using video (or video sender isn't present).
        guard connection.call.supportsVideo else { return }
        guard connection.peerConnection.senders.contains(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) else { return }

        logger.log(level: .info, message: "Starting adaptive video send loop for connectionId=\(normalizedId)")

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let current = await self.connectionManager.findConnection(with: normalizedId) else { break }
                // Stop if video isn't being used anymore.
                if !current.call.supportsVideo { break }
                if !current.peerConnection.senders.contains(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) { break }

                let report = await self.collectStats(peerConnection: current.peerConnection)
                let cfg = await self.sfuVideoQualityProfile.adaptiveConfig

                func double(_ any: Any?) -> Double? {
                    if let n = any as? NSNumber { return n.doubleValue }
                    if let s = any as? String, let v = Double(s) { return v }
                    return nil
                }

                // Find the selected candidate pair and read availableOutgoingBitrate.
                var availableOutgoingBps: Double?
                var currentRttSeconds: Double?
                for (_, stat) in report.statistics {
                    guard stat.type == "candidate-pair" else { continue }
                    let selected = (stat.values["selected"] as? Bool) ?? (stat.values["selected"] as? NSNumber)?.boolValue ?? false
                    let nominated = (stat.values["nominated"] as? Bool) ?? (stat.values["nominated"] as? NSNumber)?.boolValue ?? false
                    let state = (stat.values["state"] as? String)?.lowercased() ?? ""
                    if selected || (nominated && state == "succeeded") {
                        if let v = double(stat.values["availableOutgoingBitrate"]) {
                            availableOutgoingBps = v
                        }
                        // `currentRoundTripTime` is seconds (double) in standard WebRTC stats.
                        if let rtt = double(stat.values["currentRoundTripTime"]) ?? double(stat.values["totalRoundTripTime"]) {
                            currentRttSeconds = rtt
                        }
                        // We found the selected/nominated succeeded pair; no need to scan further.
                        break
                    }
                }

                guard let available = availableOutgoingBps, available > 0 else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                // Compute target bitrate with headroom and clamp.
                //
                // If RTT is very high, be more conservative. High latency often correlates with
                // bufferbloat / queueing and unstable throughput; backing off reduces freeze/burst.
                var headroom = cfg.headroomFactor
                if let rtt = currentRttSeconds {
                    if rtt >= 0.70 {
                        headroom = min(headroom, 0.55)
                    } else if rtt >= 0.35 {
                        headroom = min(headroom, 0.65)
                    }
                }

                let rawTarget = Int(available * headroom)
                let targetBps = max(cfg.minBitrateBps, min(cfg.maxBitrateBps, rawTarget))

                // Simple fps ladder based on ceiling; keeps motion decent on good uplink.
                let targetFps: Int = (targetBps >= cfg.highFpsThresholdBps) ? cfg.highFps : cfg.lowFps

                // Avoid thrashing: only apply when we change meaningfully.
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
                    // Apply to all local video senders.
                    for sender in current.peerConnection.senders where sender.track?.kind == kRTCMediaStreamTrackKindVideo {
                        var params = sender.parameters
                        guard !params.encodings.isEmpty else { continue }
                        for encoding in params.encodings {
                            encoding.maxBitrateBps = NSNumber(value: targetBps)
                            encoding.maxFramerate = NSNumber(value: targetFps)
                        }
                        sender.parameters = params
                    }
                    await self.setAdaptiveVideoLastApplied(connectionId: normalizedId, bitrateBps: targetBps, framerate: targetFps)
                    self.logger.log(level: .debug, message: "Adaptive video send applied (connId=\(normalizedId)): maxBitrateBps=\(targetBps) maxFramerate=\(targetFps) (availableOutgoingBitrate=\(Int(available)))")
                }

                // Emit coarse network-quality updates for UI/analytics consumers.
                func bucketByBitrate(_ bps: Double) -> RTCNetworkQuality {
                    if bps < 150_000 { return .veryPoor }
                    if bps < 300_000 { return .poor }
                    if bps < 700_000 { return .fair }
                    if bps < 1_500_000 { return .good }
                    return .excellent
                }
                func bucketByRtt(_ seconds: Double) -> RTCNetworkQuality {
                    if seconds >= 1.0 { return .veryPoor }
                    if seconds >= 0.70 { return .poor }
                    if seconds >= 0.35 { return .fair }
                    if seconds >= 0.20 { return .good }
                    return .excellent
                }
                func worse(_ a: RTCNetworkQuality, _ b: RTCNetworkQuality) -> RTCNetworkQuality {
                    // Order: excellent < good < fair < poor < veryPoor
                    func rank(_ q: RTCNetworkQuality) -> Int {
                        switch q {
                        case .excellent: return 0
                        case .good: return 1
                        case .fair: return 2
                        case .poor: return 3
                        case .veryPoor: return 4
                        }
                    }
                    return (rank(a) >= rank(b)) ? a : b
                }

                let q1 = bucketByBitrate(available)
                let q2 = currentRttSeconds.map(bucketByRtt) ?? .excellent
                let quality = worse(q1, q2)

                let rttMs: Int? = currentRttSeconds.map { Int($0 * 1000.0) }
                let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
                await self.emitNetworkQualityUpdateIfNeeded(
                    connectionId: normalizedId,
                    quality: quality,
                    availableOutgoingBitrateBps: Int(available),
                    rttMs: rttMs,
                    appliedVideoMaxBitrateBps: targetBps,
                    appliedVideoMaxFramerate: targetFps,
                    nowUptimeNs: nowUptimeNs
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
    }

    private func setAdaptiveVideoLastApplied(connectionId: String, bitrateBps: Int, framerate: Int) {
        adaptiveVideoLastAppliedByConnectionId[connectionId] = (bitrateBps, framerate)
    }
    
    /// Logs a single snapshot of outbound + inbound RTP stats.
    ///
    /// `reason` is included for correlation (e.g. "periodic", "afterAttachRemoteRenderer").
    private func logRtpEgressSnapshot(connectionId: String, report: RTCStatisticsReport, reason: String? = nil) async {
        // Aggregate outbound + inbound RTP.
        var audioPacketsSent: Int64 = 0
        var audioBytesSent: Int64 = 0
        var videoPacketsSent: Int64 = 0
        var videoBytesSent: Int64 = 0

        var audioPacketsReceived: Int64 = 0
        var audioBytesReceived: Int64 = 0
        var videoPacketsReceived: Int64 = 0
        var videoBytesReceived: Int64 = 0
        var videoFramesDecoded: Int64 = 0
        var videoFramesReceived: Int64 = 0
        
        func int64(_ any: Any?) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let s = any as? String, let v = Int64(s) { return v }
            return nil
        }
        func bool(_ any: Any?) -> Bool? {
            if let b = any as? Bool { return b }
            if let n = any as? NSNumber { return n.boolValue }
            if let s = any as? String { return (s as NSString).boolValue }
            return nil
        }
        func string(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            if let n = any as? NSNumber { return n.stringValue }
            return nil
        }
        
        // Candidate pair + DTLS state snapshot.
        var selectedPair: RTCStatistics?
        var transport: RTCStatistics?
        
        for (_, stat) in report.statistics {
            if stat.type == "outbound-rtp" {
                let kind = (string(stat.values["kind"]) ?? string(stat.values["mediaType"]) ?? "").lowercased()
                let packets = int64(stat.values["packetsSent"]) ?? 0
                let bytes = int64(stat.values["bytesSent"]) ?? 0
                if kind == "audio" {
                    audioPacketsSent += packets
                    audioBytesSent += bytes
                } else if kind == "video" {
                    videoPacketsSent += packets
                    videoBytesSent += bytes
                }
            } else if stat.type == "inbound-rtp" {
                let kind = (string(stat.values["kind"]) ?? string(stat.values["mediaType"]) ?? "").lowercased()
                let packets = int64(stat.values["packetsReceived"]) ?? 0
                let bytes = int64(stat.values["bytesReceived"]) ?? 0
                if kind == "audio" {
                    audioPacketsReceived += packets
                    audioBytesReceived += bytes
                } else if kind == "video" {
                    videoPacketsReceived += packets
                    videoBytesReceived += bytes
                    videoFramesDecoded += int64(stat.values["framesDecoded"]) ?? 0
                    videoFramesReceived += int64(stat.values["framesReceived"]) ?? 0
                }
            } else if stat.type == "candidate-pair" {
                // Most useful: selected==true (or nominated==true) + succeeded.
                let selected = bool(stat.values["selected"]) ?? false
                let nominated = bool(stat.values["nominated"]) ?? false
                let state = (string(stat.values["state"]) ?? "").lowercased()
                if selected || (nominated && state == "succeeded") {
                    selectedPair = stat
                }
            } else if stat.type == "transport" {
                transport = stat
            }
        }
        
        var pairDesc = "pair=nil"
        if let pair = selectedPair {
            let state = string(pair.values["state"]) ?? "?"
            let currentRtt = string(pair.values["currentRoundTripTime"]) ?? string(pair.values["totalRoundTripTime"]) ?? "?"
            let availableBitrate = string(pair.values["availableOutgoingBitrate"]) ?? "?"
            pairDesc = "pairState=\(state) rtt=\(currentRtt) outBitrate=\(availableBitrate)"
        }
        
        var dtlsDesc = "dtls=?"
        if let t = transport {
            dtlsDesc = "dtls=\(string(t.values["dtlsState"]) ?? "?")"
        }
        
        // Heuristics:
        // - if outbound audio+video packets stay at 0 => RTP not leaving this client
        // - if inbound video packets stay at 0 => no remote video RTP arriving (network/remote sender)
        // - if inbound video packets > 0 but framesDecoded == 0 => likely decrypt/decoder pipeline dropping frames
        let noEgress = (audioPacketsSent == 0 && videoPacketsSent == 0)
        let noIngressVideo = (videoPacketsReceived == 0)
        let ingressButNoDecode = (videoPacketsReceived > 0 && videoFramesDecoded == 0)

        let reasonDesc = reason.map { " reason=\($0)" } ?? ""
        logger.log(
            level: (noEgress || noIngressVideo || ingressButNoDecode) ? .warning : .info,
            message: "RTP stats (connId=\(connectionId)\(reasonDesc)): OUT audio packetsSent=\(audioPacketsSent) bytesSent=\(audioBytesSent) | OUT video packetsSent=\(videoPacketsSent) bytesSent=\(videoBytesSent) || IN audio packetsReceived=\(audioPacketsReceived) bytesReceived=\(audioBytesReceived) | IN video packetsReceived=\(videoPacketsReceived) bytesReceived=\(videoBytesReceived) framesReceived=\(videoFramesReceived) framesDecoded=\(videoFramesDecoded) | \(dtlsDesc) | \(pairDesc)"
        )
    }

    /// Emits a single `getStats` snapshot after an optional delay.
    ///
    /// This is intentionally **not** gated by `PQSRTCDiagnostics.criticalBugLoggingEnabled` because it is
    /// low-volume and is the fastest way to prove whether inbound video RTP is arriving (vs decrypt/decode failure).
    func logRtpStatsSnapshotOnce(connectionId: String, delayNanoseconds: UInt64 = 0, reason: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let current = await self.connectionManager.findConnection(with: normalizedId) else { return }
            let report = await self.collectStats(peerConnection: current.peerConnection)
            await self.logRtpEgressSnapshot(connectionId: normalizedId, report: report, reason: reason)
        }
    }
}

extension RTCStatisticsReport: @unchecked Sendable {}

#endif

