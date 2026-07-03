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
        if let existing = inboundVideoFlowSamplerTasksByConnectionId[normalizedId], !existing.isCancelled {
            return
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard await self.connectionManager.findConnection(with: normalizedId) != nil else { break }
                if let flow = await self.evaluateInboundRemoteVideoFlowSnapshot(connectionId: normalizedId) {
                    await self.publishInboundVideoFlowUpdate(flow)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        inboundVideoFlowSamplerTasksByConnectionId[normalizedId] = task
    }

    func stopInboundVideoFlowSampler(connectionId: String) {
        let normalizedId = connectionId.trimmingCharacters(in: .whitespacesAndNewlines).normalizedConnectionId
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
        return InboundVideoFlowSnapshot(
            deltaFramesDecoded: deltaDecoded,
            deltaPacketsReceived: deltaPackets
        )
    }
}
#endif
