import Foundation
import Testing

@testable import PQSRTC

private extension RTCSession {
    /// Number of live `createNetworkQualityStream()` subscriptions, read on the actor.
    func networkQualitySinkCount() -> Int {
        guard let sinks = Mirror(reflecting: self).children.first(where: { $0.label == "networkQualitySinks" }) else {
            return -1
        }
        return Mirror(reflecting: sinks.value).children.count
    }
}

@Suite(.serialized)
struct NetworkQualityObserverReleaseTests {
    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    @MainActor
    @Test("an observer dropped without stop() is released and its session subscription ends")
    func droppedObserverIsReleasedWithoutStop() async throws {
        let session = await RTCSession(
            iceServers: ["stun:stun.l.google.com:19302"],
            username: "",
            password: "",
            delegate: nil
        )
        var observer: RTCNetworkQualityEventObserver? = RTCNetworkQualityEventObserver()
        weak let released = observer
        observer?.start(session: session)

        #expect(await waitUntil { await session.networkQualitySinkCount() == 1 })
        await session.emitNetworkQualityUpdateIfNeeded(
            connectionId: "conn",
            quality: .poor,
            availableOutgoingBitrateBps: nil,
            rttMs: nil,
            appliedVideoMaxBitrateBps: nil,
            appliedVideoMaxFramerate: nil,
            nowUptimeNs: 1
        )
        #expect(await waitUntil { observer?.latest?.quality == .poor })

        // The host drops the observer (view goes away) without calling stop().
        observer = nil

        #expect(await waitUntil { released == nil }, "observer is still alive after its last owner dropped it")
        #expect(await waitUntil { await session.networkQualitySinkCount() == 0 }, "session still holds the dropped observer's sink")

        await session.shutdown(with: nil)
    }
}
