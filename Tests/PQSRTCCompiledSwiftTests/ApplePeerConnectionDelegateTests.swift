import Foundation
import Testing
import NeedleTailLogger

@testable import PQSRTC

#if canImport(WebRTC) && !os(Android)
import WebRTC

@Suite(.serialized)
struct ApplePeerConnectionDelegateTests {
    enum TestError: Error {
        case peerConnectionCreationFailed
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        // Using the package's factory (it calls RTCInitializeSSL())
        guard let pc = RTCSession.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw TestError.peerConnectionCreationFailed
        }
        return pc
    }

    private func nextEvent(
        from stream: AsyncStream<PeerConnectionNotifications?>,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async -> PeerConnectionNotifications? {
        return await withTaskGroup(of: PeerConnectionNotifications?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                while let item = await iterator.next() {
                    if let item { return item }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test
    func delegateYieldsIceGatheringAndSignalingStateChanges() async throws {
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        let delegate = ApplePeerConnectionDelegate(
            connectionId: "conn",
            logger: NeedleTailLogger("[test]"),
            continuation: continuation
        )

        let pc = try makePeerConnection()

        delegate.peerConnection(pc, didChange: RTCIceGatheringState.gathering)
        let event1 = await nextEvent(from: stream)

        switch event1 {
        case .iceGatheringDidChange(let connectionId, let state):
            #expect(connectionId == "conn")
            #expect(state.description == "gathering")
        default:
            Issue.record("Expected .iceGatheringDidChange")
        }

        delegate.peerConnection(pc, didChange: RTCSignalingState.haveLocalOffer)
        let event2 = await nextEvent(from: stream)

        switch event2 {
        case .signalingStateDidChange(let connectionId, let state):
            #expect(connectionId == "conn")
            #expect(state.description == "haveLocalOffer")
        default:
            Issue.record("Expected .signalingStateDidChange")
        }

        await delegate.shutdown()
    }

    @Test
    func delegateYieldsNegotiationAndIceCandidateEvents() async throws {
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        let delegate = ApplePeerConnectionDelegate(
            connectionId: "conn",
            logger: NeedleTailLogger("[test]"),
            continuation: continuation
        )

        let pc = try makePeerConnection()

        delegate.peerConnectionShouldNegotiate(pc)
        let event1 = await nextEvent(from: stream)

        switch event1 {
        case .shouldNegotiate(let connectionId):
            #expect(connectionId == "conn")
        default:
            Issue.record("Expected .shouldNegotiate")
        }

        let candidate = RTCIceCandidate(sdp: "candidate: 1 1 UDP 1234 1.2.3.4 9999 typ host", sdpMLineIndex: 0, sdpMid: "0")
        delegate.peerConnection(pc, didGenerate: candidate)
        let event2 = await nextEvent(from: stream)

        switch event2 {
        case .generatedIceCandidate(let connectionId, let sdp, let mLineIndex, let mid):
            #expect(connectionId == "conn")
            #expect(sdp.contains("candidate:"))
            #expect(mLineIndex == 0)
            #expect(mid == "0")
        default:
            Issue.record("Expected .generatedIceCandidate")
        }

        delegate.peerConnection(pc, didRemove: [candidate, candidate])
        let event3 = await nextEvent(from: stream)

        switch event3 {
        case .removedIceCandidates(let connectionId, let count):
            #expect(connectionId == "conn")
            #expect(count == 2)
        default:
            Issue.record("Expected .removedIceCandidates")
        }

        await delegate.shutdown()
    }

    @Test
    func dataChannelOpenStoresChannel_andMessageYieldsNotification() async throws {
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        let delegate = ApplePeerConnectionDelegate(
            connectionId: "conn",
            logger: NeedleTailLogger("[test]"),
            continuation: continuation
        )

        let pc = try makePeerConnection()

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let channel = pc.dataChannel(forLabel: "chat", configuration: dcConfig)
        #expect(channel != nil)

        guard let channel else {
            await delegate.shutdown()
            return
        }

        delegate.peerConnection(pc, didOpen: channel)
        let event1 = await nextEvent(from: stream)

        switch event1 {
        case .dataChannel(let connectionId, let label):
            #expect(connectionId == "conn")
            #expect(label == "chat")
        default:
            Issue.record("Expected .dataChannel")
        }

        let fetched = delegate.getDataChannel(for: "chat")
        #expect(fetched === channel)

        let payload = Data([0x01, 0x02, 0x03])
        let buffer = RTCDataBuffer(data: payload, isBinary: true)
        delegate.dataChannel(channel, didReceiveMessageWith: buffer)

        let event2 = await nextEvent(from: stream)
        switch event2 {
        case .dataChannelMessage(let connectionId, let label, let data):
            #expect(connectionId == "conn")
            #expect(label == "chat")
            #expect(data == payload)
        default:
            Issue.record("Expected .dataChannelMessage")
        }

        await delegate.shutdown()
    }

    @Test
    func emptyConnectionIdSuppressesYields() async throws {
        let (stream, continuation) = AsyncStream<PeerConnectionNotifications?>.makeStream()
        let delegate = ApplePeerConnectionDelegate(
            connectionId: "",
            logger: NeedleTailLogger("[test]"),
            continuation: continuation
        )

        let pc = try makePeerConnection()
        delegate.peerConnectionShouldNegotiate(pc)

        let event = await nextEvent(from: stream, timeoutNanoseconds: 150_000_000)
        #expect(event == nil)

        await delegate.shutdown()
    }
}
#endif
