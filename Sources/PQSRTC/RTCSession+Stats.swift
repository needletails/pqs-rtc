//
//  RTCSession+Stats.swift
//  pqs-rtc
//
//  Diagnostics: outbound RTP + selected candidate pair.
//

import Foundation
import NeedleTailLogger

extension RTCSession {
    /// Whether a duplicate participant-track event should skip renderer reattach.
    internal static func shouldSkipParticipantTrackReattach(
        hasActiveSink: Bool,
        boundTrackSharesRendererSinkWithTarget: Bool,
        rendererLayoutNeedsSinkReconcile: Bool = false,
        targetTrackIsLive: Bool = true
    ) -> Bool {
        if rendererLayoutNeedsSinkReconcile { return false }
        if hasActiveSink, !targetTrackIsLive { return true }
        return hasActiveSink && boundTrackSharesRendererSinkWithTarget
    }

    /// Minimal inbound video flow deltas published to renderer recovery observers.
    ///
    /// The full ``InboundVideoFlowCheck`` type is WebRTC-only; Android recovery uses this
    /// snapshot shape via ``inboundVideoFlowUpdateStream()``.
    struct InboundVideoFlowSnapshot: Sendable {
        let deltaFramesDecoded: Int64
        let deltaPacketsReceived: Int64

        static let inactive = InboundVideoFlowSnapshot(deltaFramesDecoded: 0, deltaPacketsReceived: 0)
    }
}

#if canImport(WebRTC)
import WebRTC

extension RTCSession {
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

    /// True when per-mid screen ingress has flatlined while other media still advances — the remote
    /// sharer likely stopped even if the SFU still advertises a stale relay `sendrecv` screen leg.
    static func screenFlowIndicatesRemoteShareStopped(_ flow: InboundVideoFlowCheck) -> Bool {
        guard flow.deltaPacketsReceived <= 0, flow.deltaFramesReceived <= 0 else { return false }
        if flow.packetsReceived == 0,
           flow.framesReceived == 0,
           flow.deltaPacketsReceived < 0 || flow.deltaFramesReceived < 0 || flow.deltaFramesDecoded < 0 {
            return true
        }
        switch flow.state {
        case .stalledIngress, .noTraffic:
            let flatScreenLeg = flow.likelyCause.contains("screen_video_flat")
                || flow.likelyCause.contains("both_audio_and_screen_video_flat")
            guard flatScreenLeg else { return false }
            // After SFU stop-forward renegotiation, per-mid screen counters can reset to zero even
            // though the sharer had been sending. Audio still advancing is enough to confirm the
            // flat line is on the screen leg, not total transport loss.
            return flow.packetsReceived > 0 || flow.deltaAudioPacketsReceived > 0
        case .advancingIngress, .decodeStalled:
            return false
        }
    }

    /// Whether a stalled remote renderer should trigger cryptor rebind + track re-attach.
    static func shouldAttemptInboundRemoteVideoRendererRecovery(
        inboundFlow: InboundVideoFlowCheck?,
        callbackAgeMs: Int64,
        hasAnyCallbacks: Bool,
        expectationAgeMs: Int64 = 0,
        cameraDecodeStallThresholdMs: Int64 = 3_000,
        prolongedStallThresholdMs: Int64 = 12_000
    ) -> Bool {
        let effectiveStallAgeMs = callbackAgeMs >= 0 ? callbackAgeMs : expectationAgeMs
        if let flow = inboundFlow {
            switch flow.state {
            case .decodeStalled:
                if effectiveStallAgeMs >= cameraDecodeStallThresholdMs,
                   flow.deltaPacketsReceived > 0 {
                    if hasAnyCallbacks, flow.deltaFramesDecoded == 0 {
                        return true
                    }
                }
                return effectiveStallAgeMs >= prolongedStallThresholdMs
            case .advancingIngress:
                // RTP and decode are moving; the heavy recovery path would churn live bindings.
                return false
            case .noTraffic, .stalledIngress:
                if flow.likelyCause == "transport_or_ice_instability" {
                    return false
                }
                break
            }
        }
        return hasAnyCallbacks && effectiveStallAgeMs >= prolongedStallThresholdMs
    }

    // MARK: - Test hooks (package-internal; used by `PQSRTCCompiledSwiftTests`)

    internal func testing_usesGroupCallAnswerSdpPolicy(for connectionId: String) -> Bool {
        isGroupCallConnection(connectionId)
    }

    internal func testing_configureGroupSessionForTests(activeConnectionId: String) {
        isGroupCall = true
        self.activeConnectionId = activeConnectionId
    }

    internal func testing_seedRemoteScreenIngressFlatSinceForTests(
        key: String,
        since date: Date
    ) {
        remoteScreenIngressFlatSinceByKey[key] = date
        if let separator = key.firstIndex(of: "|") {
            let connectionId = String(key[..<separator])
            let participantKey = String(key[key.index(after: separator)...])
            remoteScreenIngressFlatSinceByKey[
                remoteScreenIngressFlatObservationKey(connectionId: connectionId, participantKey: participantKey)
            ] = date
        }
    }

    internal func testing_seedLastInboundScreenVideoCountersForTests(
        connectionId: String,
        audioPacketsReceived: Int64,
        packetsReceived: Int64,
        framesReceived: Int64,
        framesDecoded: Int64
    ) {
        let counters = InboundVideoCounters(
            audioPacketsReceived: audioPacketsReceived,
            packetsReceived: packetsReceived,
            framesReceived: framesReceived,
            framesDecoded: framesDecoded
        )
        lastInboundScreenVideoCountersByConnectionId[connectionId] = counters
        lastInboundScreenVideoCountersByConnectionId[connectionId.normalizedConnectionId] = counters
    }

    /// Screen-share renderer recovery uses per-mid ingress so camera traffic cannot mask a stalled
    /// screen leg. Also recovers sooner when transport/ICE is unstable during SFU renegotiation.
    static func shouldAttemptInboundRemoteScreenRendererRecovery(
        screenFlow: InboundVideoFlowCheck?,
        aggregateFlow: InboundVideoFlowCheck?,
        callbackAgeMs: Int64,
        hasAnyCallbacks: Bool,
        expectationAgeMs: Int64 = 0,
        screenDecodeStallThresholdMs: Int64 = 6_000,
        transportRecoveryThresholdMs: Int64 = 4_000,
        prolongedStallThresholdMs: Int64 = 12_000
    ) -> Bool {
        let effectiveStallAgeMs = callbackAgeMs >= 0 ? callbackAgeMs : expectationAgeMs
        let transportFlow = screenFlow ?? aggregateFlow
        if let flow = transportFlow,
           flow.likelyCause == "transport_or_ice_instability",
           effectiveStallAgeMs >= transportRecoveryThresholdMs {
            return true
        }

        if let flow = screenFlow {
            switch flow.state {
            case .decodeStalled:
                if flow.packetsReceived > 0, flow.framesDecoded == 0,
                   effectiveStallAgeMs >= 3_000 {
                    return true
                }
                return effectiveStallAgeMs >= screenDecodeStallThresholdMs
            case .advancingIngress:
                if !hasAnyCallbacks {
                    return effectiveStallAgeMs >= screenDecodeStallThresholdMs
                }
                return effectiveStallAgeMs >= prolongedStallThresholdMs
            case .noTraffic, .stalledIngress:
                if !hasAnyCallbacks {
                    if effectiveStallAgeMs >= screenDecodeStallThresholdMs {
                        return true
                    }
                    if flow.packetsReceived == 0,
                       flow.likelyCause.contains("screen_video_flat"),
                       effectiveStallAgeMs >= 3_000 {
                        return true
                    }
                }
                break
            }
        }

        return shouldAttemptInboundRemoteVideoRendererRecovery(
            inboundFlow: aggregateFlow,
            callbackAgeMs: callbackAgeMs,
            hasAnyCallbacks: hasAnyCallbacks,
            expectationAgeMs: expectationAgeMs,
            prolongedStallThresholdMs: prolongedStallThresholdMs
        )
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
        stopInboundVideoFlowSampler(connectionId: normalizedId)
        lastInboundVideoCountersByConnectionId.removeValue(forKey: normalizedId)
    }

    func startInboundVideoFlowSamplerIfNeeded(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        if let existing = inboundVideoFlowSamplerTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await self.connectionManager.findConnection(with: normalizedId) != nil else { break }
                if let flow = await self.evaluateInboundRemoteVideoFlow(connectionId: normalizedId) {
                    await self.setCachedInboundVideoFlow(connectionId: normalizedId, flow: flow)
                }
                if let screenFlow = await self.evaluateInboundRemoteScreenVideoFlow(connectionId: normalizedId) {
                    await self.setCachedInboundScreenVideoFlow(connectionId: normalizedId, flow: screenFlow)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        inboundVideoFlowSamplerTasksByConnectionId[normalizedId] = task
    }

    func cachedInboundRemoteVideoFlow(connectionId: String) -> InboundVideoFlowCheck? {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        return cachedInboundVideoFlowByConnectionId[normalizedId]
    }

    func cachedInboundRemoteScreenVideoFlow(connectionId: String) -> InboundVideoFlowCheck? {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        return cachedInboundScreenVideoFlowByConnectionId[normalizedId]
    }

    private func setCachedInboundVideoFlow(connectionId: String, flow: InboundVideoFlowCheck) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        cachedInboundVideoFlowByConnectionId[normalizedId] = flow
        publishInboundVideoFlowUpdate(
            InboundVideoFlowSnapshot(
                deltaFramesDecoded: flow.deltaFramesDecoded,
                deltaPacketsReceived: flow.deltaPacketsReceived
            )
        )
    }

    private func setCachedInboundScreenVideoFlow(connectionId: String, flow: InboundVideoFlowCheck) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        cachedInboundScreenVideoFlowByConnectionId[normalizedId] = flow
    }

    func stopInboundVideoFlowSampler(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        if let task = inboundVideoFlowSamplerTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
        cachedInboundVideoFlowByConnectionId.removeValue(forKey: normalizedId)
        cachedInboundScreenVideoFlowByConnectionId.removeValue(forKey: normalizedId)
        lastInboundScreenVideoCountersByConnectionId.removeValue(forKey: normalizedId)
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
            let fastProbeDeadline = DispatchTime.now().uptimeNanoseconds + 180_000_000_000 // first 3m
            var consecutiveStalledEgressSamples = 0

            while !Task.isCancelled {
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

                let now = DispatchTime.now().uptimeNanoseconds
                let sleepNs: UInt64 = now <= fastProbeDeadline ? 2_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
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
                var captureAppearsStale = false
#if os(iOS) || os(macOS)
                var staleCaptureWrapper: RTCVideoCaptureWrapper?
#endif
                if let connection = await connectionManager.findConnection(with: connectionId),
                   let wrapper = connection.rtcVideoCaptureWrapper {
                    let snapshot = wrapper.captureTelemetrySnapshot()
                    let now = DispatchTime.now().uptimeNanoseconds
                    let ageMs: UInt64 = now >= snapshot.lastCaptureUptimeNanoseconds ? (now - snapshot.lastCaptureUptimeNanoseconds) / 1_000_000 : 0
                    captureInfo = "captureFrames=\(snapshot.capturedFrameCount), captureLastMsAgo=\(ageMs)"
                    captureAppearsStale = ageMs >= 3_000
#if os(iOS) || os(macOS)
                    staleCaptureWrapper = captureAppearsStale ? wrapper : nil
#endif
                }

                logger.log(
                    level: .warning,
                    message: "Outbound video still flat after toggle; attempting capture restart or sender rebuild (connId=\(connectionId), dOutVideoPackets=\(afterToggle.deltaPacketsSent), dOutFramesEncoded=\(afterToggle.deltaFramesEncoded), dOutFramesSent=\(afterToggle.deltaFramesSent), \(captureInfo))"
                )

#if os(iOS) || os(macOS)
                if captureAppearsStale,
                   let wrapper = staleCaptureWrapper,
                   await restartRegisteredLocalPreviewCaptureForRecovery(connectionId: connectionId, wrapper: wrapper) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let afterCaptureRestart = await evaluateOutboundLocalVideoFlow(connectionId: connectionId) {
                        let recovered = afterCaptureRestart.deltaPacketsSent > 0
                            || afterCaptureRestart.deltaFramesEncoded > 0
                            || afterCaptureRestart.deltaFramesSent > 0
                        if recovered {
                            logRtpStatsSnapshotOnce(
                                connectionId: connectionId,
                                delayNanoseconds: 500_000_000,
                                reason: "afterOutboundVideoRecoveryCaptureRestart"
                            )
                            return
                        }
                    }
                }
#endif

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
        if previous == nil {
            if packetsReceived == 0 && framesReceived == 0 {
                state = .noTraffic
            } else {
                state = framesDecoded > 0 ? .advancingIngress : .decodeStalled
            }
        } else if packetsReceived == 0 && framesReceived == 0 {
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

    /// Checks whether inbound remote *screen-share* video counters are advancing.
    ///
    /// Uses SFU remote SDP screen mids when available; otherwise sums non-camera video mids.
    func evaluateInboundRemoteScreenVideoFlow(connectionId: String) async -> InboundVideoFlowCheck? {
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

        var screenMids = Set<String>()
        if let remoteSdp = current.peerConnection.remoteDescription?.sdp,
           !remoteSdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            screenMids = Self.remoteActiveIncomingScreenShareVideoMids(in: remoteSdp)
            if screenMids.isEmpty {
                screenMids = Self.sfuRelayIncomingScreenShareVideoMids(in: remoteSdp)
            }
        }
        for mappedTrack in current.remoteScreenTracksByParticipantId.values {
            for transceiver in current.peerConnection.transceivers where transceiver.mediaType == .video {
                guard transceiver.receiver.track === mappedTrack else { continue }
                let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !mid.isEmpty else { continue }
                screenMids.insert(mid)
            }
        }

        let cameraTrackIds = Set(current.remoteVideoTracksByParticipantId.values.map(\.trackId))
        var cameraMids = Set<String>()
        for transceiver in current.peerConnection.transceivers where transceiver.mediaType == .video {
            let mid = transceiver.mid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty,
                  let track = transceiver.receiver.track as? RTCVideoTrack,
                  cameraTrackIds.contains(track.trackId)
            else { continue }
            cameraMids.insert(mid)
        }

        func isScreenMid(_ mid: String) -> Bool {
            if screenMids.contains(mid) { return true }
            if cameraMids.contains(mid) { return false }
            return mid != "1"
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
                    let mid = string(stat.values["mid"]) ?? ""
                    guard isScreenMid(mid) else { continue }
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
        let previous = lastInboundScreenVideoCountersByConnectionId[normalizedId]
        lastInboundScreenVideoCountersByConnectionId[normalizedId] = counters

        let deltaAudioPackets = audioPacketsReceived - (previous?.audioPacketsReceived ?? audioPacketsReceived)
        let deltaPackets = packetsReceived - (previous?.packetsReceived ?? packetsReceived)
        let deltaFrames = framesReceived - (previous?.framesReceived ?? framesReceived)
        let deltaDecoded = framesDecoded - (previous?.framesDecoded ?? framesDecoded)

        let state: InboundVideoFlowState
        if previous == nil {
            if packetsReceived == 0 && framesReceived == 0 {
                state = .noTraffic
            } else {
                state = framesDecoded > 0 ? .advancingIngress : .decodeStalled
            }
        } else if packetsReceived == 0 && framesReceived == 0 {
            state = .noTraffic
        } else if deltaPackets > 0 || deltaFrames > 0 {
            state = (deltaDecoded <= 0) ? .decodeStalled : .advancingIngress
        } else {
            state = .stalledIngress
        }

        let likelyCause: String = {
            switch state {
            case .advancingIngress:
                return "inbound_screen_video_advancing"
            case .decodeStalled:
                return "inbound_screen_video_advancing_but_decode_stalled"
            case .noTraffic, .stalledIngress:
                if deltaAudioPackets > 0 {
                    return "audio_advancing_screen_video_flat_remote_sender_or_sfu_screen_forward_stopped"
                }
                if dtlsState != "connected" || (selectedPairState != "succeeded" && selectedPairState != "in-progress" && selectedPairState != "inprogress") {
                    return "transport_or_ice_instability"
                }
                return "both_audio_and_screen_video_flat_remote_sender_or_sfu_stopped_or_path_stalled"
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
                if !current.call.supportsVideo { break }
                if !current.peerConnection.senders.contains(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) { break }

                let report = await self.collectStats(peerConnection: current.peerConnection)
                let isOneToOneSfu = Self.isTrueOneToOneSfuRoom(call: current.call)
                var cfg = await self.sfuAdaptiveConfig(for: current.call)
#if os(iOS)
                cfg = await self.thermalAdjustedAdaptiveVideoConfig(cfg, connectionId: normalizedId)
#endif

                func double(_ any: Any?) -> Double? {
                    if let n = any as? NSNumber { return n.doubleValue }
                    if let s = any as? String, let v = Double(s) { return v }
                    return nil
                }

                var availableOutgoingBps: Double?
                var availableIncomingBps: Double?
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
                        if let v = double(stat.values["availableIncomingBitrate"]) {
                            availableIncomingBps = v
                        }
                        if let rtt = double(stat.values["currentRoundTripTime"]) ?? double(stat.values["totalRoundTripTime"]) {
                            currentRttSeconds = rtt
                        }
                        break
                    }
                }

                let targets: AdaptiveVideoTargets
                let reportedAvailableBps: Int?
                if let available = availableOutgoingBps, available > 0 {
                    targets = RTCAdaptiveVideoTargets.compute(
                        cfg: cfg,
                        isOneToOneSfu: isOneToOneSfu,
                        reportedAvailableOutgoingBps: available,
                        currentRttSeconds: currentRttSeconds
                    )
                    reportedAvailableBps = Int(available)
                } else {
                    targets = RTCAdaptiveVideoTargets.conservativeStartupTargets(
                        cfg: cfg,
                        isOneToOneSfu: isOneToOneSfu
                    )
                    reportedAvailableBps = nil
                }

                let lastApplied = await self.adaptiveVideoLastAppliedByConnectionId[normalizedId]
                let deltaOk = RTCAdaptiveVideoTargets.shouldApply(targets, lastApplied: lastApplied)

                if deltaOk {
                    for sender in current.peerConnection.senders where sender.track?.kind == kRTCMediaStreamTrackKindVideo {
                        var params = sender.parameters
                        guard !params.encodings.isEmpty else { continue }
                        for encoding in params.encodings {
                            encoding.maxBitrateBps = NSNumber(value: targets.maxBitrateBps)
                            encoding.maxFramerate = NSNumber(value: targets.maxFramerate)
                            encoding.scaleResolutionDownBy = NSNumber(value: targets.scaleResolutionDownBy)
                        }
                        sender.parameters = params
                    }
                    await self.setAdaptiveVideoLastApplied(
                        connectionId: normalizedId,
                        bitrateBps: targets.maxBitrateBps,
                        framerate: targets.maxFramerate,
                        scaleResolutionDownBy: targets.scaleResolutionDownBy
                    )
                    self.logger.log(
                        level: .debug,
                        message: "Adaptive video send applied (connId=\(normalizedId) oneToOne=\(isOneToOneSfu)): maxBitrateBps=\(targets.maxBitrateBps) maxFramerate=\(targets.maxFramerate) scaleResolutionDownBy=\(targets.scaleResolutionDownBy) reportedAvailableBps=\(reportedAvailableBps.map(String.init) ?? "nil")"
                    )
                }

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

                let q1 = availableOutgoingBps.map(bucketByBitrate) ?? .poor
                let q2 = currentRttSeconds.map(bucketByRtt) ?? .excellent
                let quality = worse(q1, q2)

                let rttMs: Int? = currentRttSeconds.map { Int($0 * 1000.0) }
                let nowUptimeNs = DispatchTime.now().uptimeNanoseconds
                await self.emitNetworkQualityUpdateIfNeeded(
                    connectionId: normalizedId,
                    quality: quality,
                    availableOutgoingBitrateBps: reportedAvailableBps,
                    availableIncomingBitrateBps: availableIncomingBps.map { Int($0) },
                    rttMs: rttMs,
                    appliedVideoMaxBitrateBps: targets.maxBitrateBps,
                    appliedVideoMaxFramerate: targets.maxFramerate,
                    nowUptimeNs: nowUptimeNs
                )

                let sleepNs: UInt64 = deltaOk ? 2_000_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: sleepNs)
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
#if os(iOS)
        adaptiveVideoThermalStateByConnectionId.removeValue(forKey: normalizedId)
#endif
    }

    private func setAdaptiveVideoLastApplied(connectionId: String, bitrateBps: Int, framerate: Int, scaleResolutionDownBy: Double) {
        adaptiveVideoLastAppliedByConnectionId[connectionId] = (bitrateBps, framerate, scaleResolutionDownBy)
    }

#if os(iOS)
    private func thermalAdjustedAdaptiveVideoConfig(
        _ baseConfig: RTCVideoQualityProfile.AdaptiveConfig,
        connectionId: String
    ) -> RTCVideoQualityProfile.AdaptiveConfig {
        let thermalState = ProcessInfo.processInfo.thermalState
        let label = String(describing: thermalState)
        if adaptiveVideoThermalStateByConnectionId[connectionId] != label {
            adaptiveVideoThermalStateByConnectionId[connectionId] = label
            let adjusted = baseConfig.adjustedForThermalState(thermalState)
            let message: Message = "iOS thermal video profile connectionId=\(connectionId) thermalState=\(label) maxBitrateBps=\(adjusted.maxBitrateBps) fps=\(adjusted.lowFps)-\(adjusted.highFps)"
            if thermalState == .serious || thermalState == .critical {
                logger.log(level: .warning, message: message)
            } else {
                logger.log(level: .info, message: message)
            }
            return adjusted
        }
        return baseConfig.adjustedForThermalState(thermalState)
    }
#endif
    
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

    /// Per-mid screen-share diagnostics — always logs inbound/outbound RTP split by `mid` plus
    /// live transceiver + cryptor binding state. Use this to distinguish camera (`mid=1`) from
    /// screen (`mid=2`) when aggregate video counters look healthy.
    func logScreenShareDiagnostics(connectionId: String, delayNanoseconds: UInt64 = 0, reason: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            await self.logScreenShareDiagnosticsSnapshot(connectionId: normalizedId, reason: reason)
        }
    }

    private func logScreenShareDiagnosticsSnapshot(connectionId: String, reason: String) async {
        guard let connection = await connectionManager.findConnection(with: connectionId) else { return }
        let report = await collectStats(peerConnection: connection.peerConnection)

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

        var inboundByMid: [String: (packets: Int64, framesReceived: Int64, framesDecoded: Int64)] = [:]
        var outboundByMid: [String: (packets: Int64, framesEncoded: Int64, framesSent: Int64)] = [:]

        for (_, stat) in report.statistics {
            let kind = (string(stat.values["kind"]) ?? string(stat.values["mediaType"]) ?? "").lowercased()
            let mid = string(stat.values["mid"]) ?? "?"
            if stat.type == "inbound-rtp", kind == "video" {
                var entry = inboundByMid[mid] ?? (0, 0, 0)
                entry.packets += int64(stat.values["packetsReceived"]) ?? 0
                entry.framesReceived += int64(stat.values["framesReceived"]) ?? 0
                entry.framesDecoded += int64(stat.values["framesDecoded"]) ?? 0
                inboundByMid[mid] = entry
            } else if stat.type == "outbound-rtp", kind == "video" {
                var entry = outboundByMid[mid] ?? (0, 0, 0)
                entry.packets += int64(stat.values["packetsSent"]) ?? 0
                entry.framesEncoded += int64(stat.values["framesEncoded"]) ?? 0
                entry.framesSent += int64(stat.values["framesSent"]) ?? 0
                outboundByMid[mid] = entry
            }
        }

        let inboundDesc = inboundByMid.keys.sorted().map { mid in
            let e = inboundByMid[mid]!
            return "mid=\(mid):pkts=\(e.packets),framesRx=\(e.framesReceived),framesDec=\(e.framesDecoded)"
        }.joined(separator: ";")
        let outboundDesc = outboundByMid.keys.sorted().map { mid in
            let e = outboundByMid[mid]!
            return "mid=\(mid):pkts=\(e.packets),framesEnc=\(e.framesEncoded),framesSent=\(e.framesSent)"
        }.joined(separator: ";")

        let transceiverDesc = connection.peerConnection.transceivers
            .filter { $0.mediaType == .video }
            .map { t in
                let mid = t.mid.trimmingCharacters(in: .whitespacesAndNewlines)
                let recvId = t.receiver.track?.trackId ?? "nil"
                let sendId = t.sender.track?.trackId ?? "nil"
                return "mid=\(mid.isEmpty ? "?" : mid),dir=\(t.direction),recv=\(recvId),send=\(sendId)"
            }
            .joined(separator: ";")

        let screenBindingDesc = connection.screenReceiverCryptorBindingsByParticipantId.map { key, binding in
            "\(key):track=\(binding.trackId),receiver=\(binding.receiverId)"
        }.sorted().joined(separator: ";")

        let senderBinding = connection.screenSenderCryptorBinding.map {
            "track=\($0.trackId),sender=\($0.senderId)"
        } ?? "nil"

        let remoteScreenTracks = connection.remoteScreenTracksByParticipantId.map { key, track in
            "\(key)=\(track.trackId)"
        }.sorted().joined(separator: ";")

        logger.log(
            level: .info,
            message: "Screen-share diagnostics (connId=\(connectionId) reason=\(reason)): inboundVideo=[\(inboundDesc.isEmpty ? "none" : inboundDesc)] outboundVideo=[\(outboundDesc.isEmpty ? "none" : outboundDesc)] transceivers=[\(transceiverDesc.isEmpty ? "none" : transceiverDesc)] remoteScreenTracks=[\(remoteScreenTracks.isEmpty ? "none" : remoteScreenTracks)] screenReceiverCryptors=[\(screenBindingDesc.isEmpty ? "none" : screenBindingDesc)] screenSenderCryptorBinding=\(senderBinding)"
        )
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
