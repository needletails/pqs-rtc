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
    enum InboundVideoFlowState: String, Sendable {
        case noTraffic
        case stalledIngress
        case advancingIngress
        case decodeStalled
    }

    struct InboundVideoFlowCheck: Sendable {
        let state: InboundVideoFlowState
        let likelyCause: String
        let audioPacketsReceived: Int64
        let packetsReceived: Int64
        let framesReceived: Int64
        let framesDecoded: Int64
        let deltaAudioPacketsReceived: Int64
        let deltaPacketsReceived: Int64
        let deltaFramesReceived: Int64
        let deltaFramesDecoded: Int64
        let dtlsState: String
        let selectedPairState: String
    }

    enum OutboundVideoFlowState: String, Sendable {
        case noTraffic
        case stalledEgress
        case advancingEgress
        case encodeStalled
    }

    struct OutboundVideoFlowCheck: Sendable {
        let state: OutboundVideoFlowState
        let likelyCause: String
        let audioPacketsSent: Int64
        let packetsSent: Int64
        let framesEncoded: Int64
        let framesSent: Int64
        let deltaAudioPacketsSent: Int64
        let deltaPacketsSent: Int64
        let deltaFramesEncoded: Int64
        let deltaFramesSent: Int64
        let dtlsState: String
        let selectedPairState: String
    }

    /// Starts an inbound remote video probe (diagnostics only).
    ///
    /// Logs at `.trace` when `PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled` is true
    /// (DEBUG by default; Release + `PQSRTC_REMOTE_VIDEO_TRACE_LOGGING=1`).
    ///
    /// This runs after a remote renderer is attached and answers:
    /// - do inbound video packets ever arrive?
    /// - does decode advance once packets arrive?
    /// - is audio advancing while video remains flat?
    func startInboundVideoFlowProbe(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        guard PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled else { return }
        if let existing = inboundVideoFlowProbeTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        logger.log(level: .trace, message: "Starting inbound video flow probe for connectionId=\(normalizedId)")
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let deadline = DispatchTime.now().uptimeNanoseconds + 45_000_000_000 // 45s
            while !Task.isCancelled {
                if DispatchTime.now().uptimeNanoseconds > deadline { break }
                guard let connection = await self.connectionManager.findConnection(with: normalizedId) else { break }

                if let flow = await self.evaluateInboundRemoteVideoFlow(connectionId: normalizedId) {
                    let remoteTrackId = connection.remoteVideoTrack?.trackId ?? "nil"
                    let remoteTrackEnabled = connection.remoteVideoTrack?.isEnabled ?? false
                    self.logger.log(
                        level: .trace,
                        message: "Inbound video probe (connId=\(normalizedId), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), remoteTrackId=\(remoteTrackId), remoteTrackEnabled=\(remoteTrackEnabled), inAudioPackets=\(flow.audioPacketsReceived), inVideoPackets=\(flow.packetsReceived), inFramesReceived=\(flow.framesReceived), inFramesDecoded=\(flow.framesDecoded), dInAudioPackets=\(flow.deltaAudioPacketsReceived), dInVideoPackets=\(flow.deltaPacketsReceived), dInFramesReceived=\(flow.deltaFramesReceived), dInFramesDecoded=\(flow.deltaFramesDecoded), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState))"
                    )
                } else {
                    self.logger.log(level: .trace, message: "Inbound video probe could not read stats for connectionId=\(normalizedId)")
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        inboundVideoFlowProbeTasksByConnectionId[normalizedId] = task
    }

    func stopInboundVideoFlowProbe(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let task = inboundVideoFlowProbeTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
        lastInboundVideoCountersByConnectionId.removeValue(forKey: normalizedId)
    }

    /// Starts a local outbound video probe (includes optional sender recovery; probe logs are trace-gated).
    ///
    /// This runs on both caller and callee and is intended to correlate with inbound probes:
    /// - outbound video advancing + remote inbound video flat => likely SFU forwarding issue
    /// - outbound video flat + remote inbound video flat => likely sender capture/encode/send issue
    func startOutboundVideoFlowProbe(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        if let existing = outboundVideoFlowProbeTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
            logger.log(level: .trace, message: "Starting outbound video flow probe for connectionId=\(normalizedId)")
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let deadline = DispatchTime.now().uptimeNanoseconds + 180_000_000_000 // 3m
            var consecutiveStalledEgressSamples = 0

            while !Task.isCancelled {
                if DispatchTime.now().uptimeNanoseconds > deadline { break }
                guard await self.connectionManager.findConnection(with: normalizedId) != nil else { break }

                if let flow = await self.evaluateOutboundLocalVideoFlow(connectionId: normalizedId) {
                    if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                        self.logger.log(
                            level: .trace,
                            message: "Outbound video probe (connId=\(normalizedId), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dtls=\(flow.dtlsState), pair=\(flow.selectedPairState), outAudioPackets=\(flow.audioPacketsSent), outVideoPackets=\(flow.packetsSent), outFramesEncoded=\(flow.framesEncoded), outFramesSent=\(flow.framesSent), dOutAudioPackets=\(flow.deltaAudioPacketsSent), dOutVideoPackets=\(flow.deltaPacketsSent), dOutFramesEncoded=\(flow.deltaFramesEncoded), dOutFramesSent=\(flow.deltaFramesSent))"
                        )
                    }
                    if await self.shouldAttemptOutboundVideoRecovery(flow: flow, connectionId: normalizedId) {
                        consecutiveStalledEgressSamples += 1
                        if consecutiveStalledEgressSamples >= 3 {
                            await self.performOutboundVideoEgressRecovery(connectionId: normalizedId, flow: flow)
                            consecutiveStalledEgressSamples = 0
                        }
                    } else {
                        consecutiveStalledEgressSamples = 0
                    }
                } else if PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled {
                    self.logger.log(level: .trace, message: "Outbound video probe could not read stats for connectionId=\(normalizedId)")
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        outboundVideoFlowProbeTasksByConnectionId[normalizedId] = task
    }

    func stopOutboundVideoFlowProbe(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let task = outboundVideoFlowProbeTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
        lastOutboundVideoCountersByConnectionId.removeValue(forKey: normalizedId)
        lastOutboundVideoRecoveryUptimeNsByConnectionId.removeValue(forKey: normalizedId)
    }

    private func shouldAttemptOutboundVideoRecovery(
        flow: OutboundVideoFlowCheck,
        connectionId: String
    ) async -> Bool {
        let shouldConsiderState: Bool = {
            switch flow.state {
            case .stalledEgress, .encodeStalled:
                return true
            case .noTraffic:
                return true
            case .advancingEgress:
                return false
            }
        }()
        guard shouldConsiderState else { return false }
        guard flow.dtlsState == "connected" else { return false }
        guard flow.selectedPairState == "succeeded" || flow.selectedPairState == "in-progress" || flow.selectedPairState == "inprogress" else { return false }
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return false }
        guard connection.call.supportsVideo else { return false }
        guard connection.localVideoTrack?.isEnabled == true else { return false } // avoid fighting user mute
        // Typical case: audio is advancing while video is flat -> sender-side video stall.
        if flow.deltaAudioPacketsSent > 0 || flow.audioPacketsSent > 0 {
            return true
        }
        // Also recover when both audio+video are flat but DTLS/ICE are healthy.
        // This catches "media never started" sessions where transport came up but sender paths never began.
        if flow.state == .noTraffic {
            return true
        }
        return false
    }

    private func performOutboundVideoEgressRecovery(
        connectionId: String,
        flow: OutboundVideoFlowCheck
    ) async {
        let now = DispatchTime.now().uptimeNanoseconds
        let last = lastOutboundVideoRecoveryUptimeNsByConnectionId[connectionId] ?? 0
        // Throttle attempts to avoid flapping.
        if last > 0, now >= last, now - last < 12_000_000_000 {
            return
        }
        lastOutboundVideoRecoveryUptimeNsByConnectionId[connectionId] = now

        logger.log(
            level: .warning,
            message: "Outbound video appears stalled while transport/audio are healthy; attempting sender-side video recovery (connId=\(connectionId), flow=\(flow.state.rawValue), cause=\(flow.likelyCause), dOutVideoPackets=\(flow.deltaPacketsSent), dOutFramesEncoded=\(flow.deltaFramesEncoded), dOutFramesSent=\(flow.deltaFramesSent))"
        )

        // If absolutely no media is flowing despite connected transport, kick both media senders once.
        if flow.state == .noTraffic && flow.audioPacketsSent == 0 && flow.deltaAudioPacketsSent <= 0 {
            try? await setAudioTrack(isEnabled: false, connectionId: connectionId)
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? await setAudioTrack(isEnabled: true, connectionId: connectionId)
        }

        // Step 1: cheap sender-path toggle.
        await setVideoTrack(isEnabled: false, connectionId: connectionId)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await setVideoTrack(isEnabled: true, connectionId: connectionId)

        // Step 2: verify whether counters resumed after toggle.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let afterToggle = await evaluateOutboundLocalVideoFlow(connectionId: connectionId) {
            let stillFlat = afterToggle.deltaPacketsSent <= 0 && afterToggle.deltaFramesEncoded <= 0 && afterToggle.deltaFramesSent <= 0
            if stillFlat {
                var captureInfo = "captureTelemetry=unavailable"
                if let connection = await connectionManager.findConnection(with: connectionId),
                   let wrapper = connection.rtcVideoCaptureWrapper {
                    let snapshot = wrapper.captureTelemetrySnapshot()
                    let now = DispatchTime.now().uptimeNanoseconds
                    let ageMs: UInt64 = now >= snapshot.lastCaptureUptimeNanoseconds ? (now - snapshot.lastCaptureUptimeNanoseconds) / 1_000_000 : 0
                    captureInfo = "captureFrames=\(snapshot.capturedFrameCount), captureLastMsAgo=\(ageMs)"
                }

                logger.log(
                    level: .warning,
                    message: "Outbound video still flat after toggle; escalating to sender pipeline rebuild (connId=\(connectionId), dOutVideoPackets=\(afterToggle.deltaPacketsSent), dOutFramesEncoded=\(afterToggle.deltaFramesEncoded), dOutFramesSent=\(afterToggle.deltaFramesSent), \(captureInfo))"
                )

                if await restartLocalVideoSenderPipeline(connectionId: connectionId) {
                    await setVideoTrack(isEnabled: true, connectionId: connectionId)
                    logRtpStatsSnapshotOnce(
                        connectionId: connectionId,
                        delayNanoseconds: 2_000_000_000,
                        reason: "afterOutboundVideoRecoveryRebuild"
                    )
                    return
                }
            }
        }

        // Fallback snapshot for non-escalated or failed escalation paths.
        logRtpStatsSnapshotOnce(connectionId: connectionId, delayNanoseconds: 2_000_000_000, reason: "afterOutboundVideoRecoveryToggle")
    }
    
    /// Starts a periodic WebRTC stats loop that answers:
    /// - are we sending outbound RTP at all?
    /// - which ICE candidate pair is selected?
    /// - is DTLS connected?
    ///
    /// This is gated by `PQSRTCDiagnostics.criticalBugLoggingEnabled` and `remoteVideoTraceLoggingEnabled`
    /// (the loop only emits `.trace` RTP snapshots).
    func startOutboundRtpStatsLoggingIfEnabled(connectionId: String) async {
        guard PQSRTCDiagnostics.criticalBugLoggingEnabled else { return }
        guard PQSRTCDiagnostics.remoteVideoTraceLoggingEnabled else { return }
        
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

    private func compactRtpStatsDetails(report: RTCStatisticsReport) -> String {
        func string(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            if let n = any as? NSNumber { return n.stringValue }
            return nil
        }

        var entries: [String] = []
        for (statId, stat) in report.statistics {
            guard stat.type == "inbound-rtp" || stat.type == "outbound-rtp" else { continue }
            let values = stat.values
            let kind = (string(values["kind"]) ?? string(values["mediaType"]) ?? "?").lowercased()
            let ssrc = string(values["ssrc"]) ?? "?"
            let mid = string(values["mid"]) ?? string(values["mediaSourceId"]) ?? "?"
            let track = string(values["trackIdentifier"]) ?? string(values["trackId"]) ?? "?"
            let codec = string(values["codecId"]) ?? "?"
            let transportId = string(values["transportId"]) ?? "?"
            let packets = string(values["packetsReceived"]) ?? string(values["packetsSent"]) ?? "0"
            let bytes = string(values["bytesReceived"]) ?? string(values["bytesSent"]) ?? "0"
            let framesReceived = string(values["framesReceived"]) ?? "0"
            let framesDecoded = string(values["framesDecoded"]) ?? "0"
            let framesSent = string(values["framesSent"]) ?? "0"
            let framesEncoded = string(values["framesEncoded"]) ?? "0"
            let packetsLost = string(values["packetsLost"]) ?? "0"
            let jitter = string(values["jitter"]) ?? "?"
            entries.append("\(stat.type)#\(statId)(kind=\(kind),ssrc=\(ssrc),mid=\(mid),track=\(track),codec=\(codec),transport=\(transportId),packets=\(packets),bytes=\(bytes),framesReceived=\(framesReceived),framesDecoded=\(framesDecoded),framesSent=\(framesSent),framesEncoded=\(framesEncoded),lost=\(packetsLost),jitter=\(jitter))")
        }

        let sorted = entries.sorted()
        guard !sorted.isEmpty else { return "rtp=[]" }
        return sorted.prefix(16).joined(separator: ";")
    }

    /// Checks whether inbound remote video counters are advancing for a connection.
    ///
    /// This is used to distinguish:
    /// - sender/network stopped (`noTraffic` / `stalledIngress`)
    /// - media still arriving but decode/render pipeline is stuck (`advancingIngress` / `decodeStalled`)
    func evaluateInboundRemoteVideoFlow(connectionId: String) async -> InboundVideoFlowCheck? {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return nil }
        guard let current = await connectionManager.findConnection(with: normalizedId) else { return nil }

        let report = await collectStats(peerConnection: current.peerConnection)

        func int64(_ any: Any?) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let s = any as? String, let v = Int64(s) { return v }
            return nil
        }
        func string(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            if let n = any as? NSNumber { return n.stringValue }
            return nil
        }

        var packetsReceived: Int64 = 0
        var framesReceived: Int64 = 0
        var framesDecoded: Int64 = 0
        var audioPacketsReceived: Int64 = 0
        var selectedPairState = "unknown"
        var dtlsState = "unknown"

        for (_, stat) in report.statistics {
            if stat.type == "inbound-rtp" {
                let kind = (string(stat.values["kind"]) ?? string(stat.values["mediaType"]) ?? "").lowercased()
                if kind == "audio" {
                    audioPacketsReceived += int64(stat.values["packetsReceived"]) ?? 0
                } else if kind == "video" {
                    packetsReceived += int64(stat.values["packetsReceived"]) ?? 0
                    framesReceived += int64(stat.values["framesReceived"]) ?? 0
                    framesDecoded += int64(stat.values["framesDecoded"]) ?? 0
                }
            } else if stat.type == "candidate-pair" {
                let selected = (stat.values["selected"] as? Bool) ?? (stat.values["selected"] as? NSNumber)?.boolValue ?? false
                let nominated = (stat.values["nominated"] as? Bool) ?? (stat.values["nominated"] as? NSNumber)?.boolValue ?? false
                let state = (string(stat.values["state"]) ?? "unknown").lowercased()
                if selected || (nominated && state == "succeeded") {
                    selectedPairState = state
                }
            } else if stat.type == "transport" {
                dtlsState = (string(stat.values["dtlsState"]) ?? "unknown").lowercased()
            }
        }

        let counters = InboundVideoCounters(
            audioPacketsReceived: audioPacketsReceived,
            packetsReceived: packetsReceived,
            framesReceived: framesReceived,
            framesDecoded: framesDecoded
        )
        let previous = lastInboundVideoCountersByConnectionId[normalizedId]
        lastInboundVideoCountersByConnectionId[normalizedId] = counters

        let deltaAudioPackets = audioPacketsReceived - (previous?.audioPacketsReceived ?? audioPacketsReceived)
        let deltaPackets = packetsReceived - (previous?.packetsReceived ?? packetsReceived)
        let deltaFrames = framesReceived - (previous?.framesReceived ?? framesReceived)
        let deltaDecoded = framesDecoded - (previous?.framesDecoded ?? framesDecoded)

        let state: InboundVideoFlowState
        if packetsReceived == 0 && framesReceived == 0 {
            state = .noTraffic
        } else if deltaPackets > 0 || deltaFrames > 0 {
            state = (deltaDecoded <= 0) ? .decodeStalled : .advancingIngress
        } else {
            state = .stalledIngress
        }

        let likelyCause: String = {
            switch state {
            case .advancingIngress:
                return "inbound_video_advancing"
            case .decodeStalled:
                return "inbound_video_advancing_but_decode_stalled"
            case .noTraffic, .stalledIngress:
                if deltaAudioPackets > 0 {
                    return "audio_advancing_video_flat_remote_sender_or_sfu_video_forward_stopped"
                }
                if dtlsState != "connected" || (selectedPairState != "succeeded" && selectedPairState != "in-progress" && selectedPairState != "inprogress") {
                    return "transport_or_ice_instability"
                }
                return "both_audio_and_video_flat_remote_sender_or_sfu_stopped_or_path_stalled"
            }
        }()

        return InboundVideoFlowCheck(
            state: state,
            likelyCause: likelyCause,
            audioPacketsReceived: audioPacketsReceived,
            packetsReceived: packetsReceived,
            framesReceived: framesReceived,
            framesDecoded: framesDecoded,
            deltaAudioPacketsReceived: deltaAudioPackets,
            deltaPacketsReceived: deltaPackets,
            deltaFramesReceived: deltaFrames,
            deltaFramesDecoded: deltaDecoded,
            dtlsState: dtlsState,
            selectedPairState: selectedPairState
        )
    }

    /// Checks whether local outbound video counters are advancing for a connection.
    ///
    /// This helps identify sender-side stalls (capture/encode/send) vs upstream forwarding issues.
    func evaluateOutboundLocalVideoFlow(connectionId: String) async -> OutboundVideoFlowCheck? {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return nil }
        guard let current = await connectionManager.findConnection(with: normalizedId) else { return nil }

        let report = await collectStats(peerConnection: current.peerConnection)

        func int64(_ any: Any?) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let s = any as? String, let v = Int64(s) { return v }
            return nil
        }
        func string(_ any: Any?) -> String? {
            if let s = any as? String { return s }
            if let n = any as? NSNumber { return n.stringValue }
            return nil
        }

        var packetsSent: Int64 = 0
        var framesEncoded: Int64 = 0
        var framesSent: Int64 = 0
        var audioPacketsSent: Int64 = 0
        var selectedPairState = "unknown"
        var dtlsState = "unknown"

        for (_, stat) in report.statistics {
            if stat.type == "outbound-rtp" {
                let kind = (string(stat.values["kind"]) ?? string(stat.values["mediaType"]) ?? "").lowercased()
                if kind == "audio" {
                    audioPacketsSent += int64(stat.values["packetsSent"]) ?? 0
                } else if kind == "video" {
                    packetsSent += int64(stat.values["packetsSent"]) ?? 0
                    framesEncoded += int64(stat.values["framesEncoded"]) ?? 0
                    framesSent += int64(stat.values["framesSent"]) ?? 0
                }
            } else if stat.type == "candidate-pair" {
                let selected = (stat.values["selected"] as? Bool) ?? (stat.values["selected"] as? NSNumber)?.boolValue ?? false
                let nominated = (stat.values["nominated"] as? Bool) ?? (stat.values["nominated"] as? NSNumber)?.boolValue ?? false
                let state = (string(stat.values["state"]) ?? "unknown").lowercased()
                if selected || (nominated && state == "succeeded") {
                    selectedPairState = state
                }
            } else if stat.type == "transport" {
                dtlsState = (string(stat.values["dtlsState"]) ?? "unknown").lowercased()
            }
        }

        let counters = OutboundVideoCounters(
            audioPacketsSent: audioPacketsSent,
            packetsSent: packetsSent,
            framesEncoded: framesEncoded,
            framesSent: framesSent
        )
        let previous = lastOutboundVideoCountersByConnectionId[normalizedId]
        lastOutboundVideoCountersByConnectionId[normalizedId] = counters

        let deltaAudioPackets = audioPacketsSent - (previous?.audioPacketsSent ?? audioPacketsSent)
        let deltaPackets = packetsSent - (previous?.packetsSent ?? packetsSent)
        let deltaEncoded = framesEncoded - (previous?.framesEncoded ?? framesEncoded)
        let deltaFramesSent = framesSent - (previous?.framesSent ?? framesSent)

        let state: OutboundVideoFlowState
        if packetsSent == 0 && framesEncoded == 0 && framesSent == 0 {
            state = .noTraffic
        } else if deltaPackets > 0 || deltaFramesSent > 0 {
            state = (deltaEncoded <= 0) ? .encodeStalled : .advancingEgress
        } else {
            state = .stalledEgress
        }

        let likelyCause: String = {
            switch state {
            case .advancingEgress:
                return "outbound_video_advancing"
            case .encodeStalled:
                return "outbound_video_packets_advancing_but_frames_encoded_flat"
            case .noTraffic, .stalledEgress:
                if deltaAudioPackets > 0 {
                    return "audio_advancing_video_flat_local_sender_video_muted_or_capture_encode_send_stopped"
                }
                if dtlsState != "connected" || (selectedPairState != "succeeded" && selectedPairState != "in-progress" && selectedPairState != "inprogress") {
                    return "transport_or_ice_instability"
                }
                return "both_audio_and_video_outbound_flat_local_sender_not_sending"
            }
        }()

        return OutboundVideoFlowCheck(
            state: state,
            likelyCause: likelyCause,
            audioPacketsSent: audioPacketsSent,
            packetsSent: packetsSent,
            framesEncoded: framesEncoded,
            framesSent: framesSent,
            deltaAudioPacketsSent: deltaAudioPackets,
            deltaPacketsSent: deltaPackets,
            deltaFramesEncoded: deltaEncoded,
            deltaFramesSent: deltaFramesSent,
            dtlsState: dtlsState,
            selectedPairState: selectedPairState
        )
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
    /// This is intentionally low-volume and always available in release builds for black-video triage.
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
        let anomalyNote = (noEgress || noIngressVideo || ingressButNoDecode)
            ? " [anomaly: noEgress=\(noEgress) noIngressVideo=\(noIngressVideo) ingressButNoDecode=\(ingressButNoDecode)]"
            : ""
        let rtpDetails = compactRtpStatsDetails(report: report)
        if noEgress || noIngressVideo || ingressButNoDecode {
            logger.log(
                level: .warning,
                message: "RTP stats (connId=\(connectionId)\(reasonDesc))\(anomalyNote): OUT audio packetsSent=\(audioPacketsSent) bytesSent=\(audioBytesSent) | OUT video packetsSent=\(videoPacketsSent) bytesSent=\(videoBytesSent) || IN audio packetsReceived=\(audioPacketsReceived) bytesReceived=\(audioBytesReceived) | IN video packetsReceived=\(videoPacketsReceived) bytesReceived=\(videoBytesReceived) framesReceived=\(videoFramesReceived) framesDecoded=\(videoFramesDecoded) | \(dtlsDesc) | \(pairDesc) | details=\(rtpDetails)"
            )
        } else {
            logger.log(
                level: .info,
                message: "RTP stats (connId=\(connectionId)\(reasonDesc))\(anomalyNote): OUT audio packetsSent=\(audioPacketsSent) bytesSent=\(audioBytesSent) | OUT video packetsSent=\(videoPacketsSent) bytesSent=\(videoBytesSent) || IN audio packetsReceived=\(audioPacketsReceived) bytesReceived=\(audioBytesReceived) | IN video packetsReceived=\(videoPacketsReceived) bytesReceived=\(videoBytesReceived) framesReceived=\(videoFramesReceived) framesDecoded=\(videoFramesDecoded) | \(dtlsDesc) | \(pairDesc)"
            )
        }
    }

    /// Emits a single `getStats` snapshot after an optional delay.
    ///
    /// Always runs to capture low-volume black-video diagnostics in release builds.
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
