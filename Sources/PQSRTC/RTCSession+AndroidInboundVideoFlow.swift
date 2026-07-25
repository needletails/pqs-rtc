//
//  RTCSession+AndroidInboundVideoFlow.swift
//  pqs-rtc
//
//  Inbound video flow sampling for Android renderer recovery.
//

#if os(Android)
import Foundation

extension RTCSession {
    func startInboundVideoFlowSamplerIfNeeded(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return }
        // Do not use Task.isCancelled alone: a finished sampler leaves isCancelled==false and
        // used to permanently block restart. Track active state explicitly (C1).
        if inboundVideoFlowSamplerActiveByConnectionId[normalizedId] == true {
            return
        }

        let generation = (inboundVideoFlowSamplerGenerationByConnectionId[normalizedId] ?? 0) + 1
        inboundVideoFlowSamplerGenerationByConnectionId[normalizedId] = generation
        inboundVideoFlowSamplerActiveByConnectionId[normalizedId] = true

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await self.connectionManager.findConnection(with: normalizedId) != nil else { break }
                if let flow = await self.evaluateInboundRemoteVideoFlowSnapshot(connectionId: normalizedId) {
                    await self.publishInboundVideoFlowUpdate(flow)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            await self.clearInboundVideoFlowSamplerTaskIfCurrent(
                connectionId: normalizedId,
                generation: generation)
        }
        inboundVideoFlowSamplerTasksByConnectionId[normalizedId] = task
    }

    func stopInboundVideoFlowSampler(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        let generation = (inboundVideoFlowSamplerGenerationByConnectionId[normalizedId] ?? 0) + 1
        inboundVideoFlowSamplerGenerationByConnectionId[normalizedId] = generation
        inboundVideoFlowSamplerActiveByConnectionId[normalizedId] = false
        if let task = inboundVideoFlowSamplerTasksByConnectionId.removeValue(forKey: normalizedId) {
            task.cancel()
        }
        lastInboundVideoCountersByConnectionId.removeValue(forKey: normalizedId)
    }

    private func evaluateInboundRemoteVideoFlowSnapshot(connectionId: String) async -> InboundVideoFlowSnapshot? {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
        guard !normalizedId.isEmpty else { return nil }
        guard await connectionManager.findConnection(with: normalizedId) != nil else { return nil }
        guard let counters = await rtcClient.getInboundRemoteVideoCounters() else { return nil }

        let previous = lastInboundVideoCountersByConnectionId[normalizedId]
        lastInboundVideoCountersByConnectionId[normalizedId] = counters

        let deltaPackets = counters.packetsReceived - (previous?.packetsReceived ?? counters.packetsReceived)
        let deltaDecoded = counters.framesDecoded - (previous?.framesDecoded ?? counters.framesDecoded)
        let state: InboundVideoFlowState
        if deltaPackets > 0 && deltaDecoded <= 0 {
            state = .decodeStalled
        } else if deltaPackets > 0 || deltaDecoded > 0 {
            state = .advancingIngress
        } else if counters.packetsReceived > 0 {
            state = .stalledIngress
        } else {
            state = .noTraffic
        }
        return InboundVideoFlowSnapshot(
            state: state,
            deltaFramesDecoded: deltaDecoded,
            deltaPacketsReceived: deltaPackets
        )
    }
}
#endif
