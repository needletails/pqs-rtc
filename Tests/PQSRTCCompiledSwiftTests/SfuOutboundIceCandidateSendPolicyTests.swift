import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU outbound ICE candidate send policy")
struct SfuOutboundIceCandidateSendPolicyTests {
    @Test("1:1 always encrypts regardless of ICE or pending SDP")
    func oneToOneAlwaysEncrypts() {
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: false,
            iceIsConnectedOrCompleted: false,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: false) == .encryptNow)
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: false,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: true,
            isPreConnectJoinBurst: true) == .encryptNow)
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: false,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: true) == .encryptNow)
    }

    @Test("group holds pre-encrypt behind offer or answer regardless of ICE")
    func groupHoldsBehindOfferOrAnswer() {
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: false,
            hasPendingOfferOrAnswer: true,
            isPreConnectJoinBurst: false) == .keepBuffered)
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: true,
            isPreConnectJoinBurst: true) == .keepBuffered)
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: true,
            isPreConnectJoinBurst: false) == .keepBuffered)
    }

    @Test("group ICE connected drops the un-encrypted pre-connect join burst")
    func groupIceUpDropsJoinBurst() {
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: true) == .dropBuffered)
    }

    @Test("group ICE up continual-gather candidate encrypts when the lane is free")
    func groupPostIceContinualCandidateEncrypts() {
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: true,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: false) == .encryptNow)
    }

    @Test("group ICE not up still trickles when no offer or answer is pending")
    func groupIceCheckingStillTrickles() {
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: false,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: false) == .encryptNow)
        #expect(SfuOutboundIceCandidateSendPolicy.decide(
            isGroupOrConference: true,
            iceIsConnectedOrCompleted: false,
            hasPendingOfferOrAnswer: false,
            isPreConnectJoinBurst: true) == .encryptNow)
    }

    /// `.mediaReady` is not an ICE gate. The wired predicate must ignore it so
    /// candidates still encrypt while mediaReady sits in the lane.
    @Test("pending-offer-or-answer predicate ignores mediaReady")
    func pendingOfferOrAnswerIgnoresMediaReady() {
        #expect(!TaskProcessor.hasPendingOfferOrAnswer(flags: []))
        #expect(!TaskProcessor.hasPendingOfferOrAnswer(flags: [.mediaReady]))
        #expect(!TaskProcessor.hasPendingOfferOrAnswer(flags: [.candidate, .mediaReady]))
        #expect(TaskProcessor.hasPendingOfferOrAnswer(flags: [.offer]))
        #expect(TaskProcessor.hasPendingOfferOrAnswer(flags: [.answer]))
        #expect(TaskProcessor.hasPendingOfferOrAnswer(flags: [.candidate, .offer, .mediaReady]))
        #expect(!TaskProcessor.isPendingOfferOrAnswerFlag(.mediaReady))
        #expect(!TaskProcessor.isPendingOfferOrAnswerFlag(.candidate))
        #expect(TaskProcessor.isPendingOfferOrAnswerFlag(.offer))
        #expect(TaskProcessor.isPendingOfferOrAnswerFlag(.answer))
    }

    @Test("candidate encrypt path consults the policy before feedTask")
    func candidateEncryptPathConsultsPolicy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cipher = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+RTCCipherTransport.swift"
            ),
            encoding: .utf8
        )
        let exchange = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Exchange.swift"
            ),
            encoding: .utf8
        )
        let notifications = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift"
            ),
            encoding: .utf8
        )
        #expect(cipher.contains("SfuOutboundIceCandidateSendPolicy.decide"))
        #expect(cipher.contains("hasPendingOfferOrAnswerOutbound"))
        #expect(cipher.contains("isPreConnectJoinBurst"))
        #expect(exchange.contains("isPreConnectJoinBurst: true"))
        #expect(exchange.contains("dropUnencryptedPreConnectCandidateBurst"))
        #expect(exchange.contains("beginOutboundSendWait(matching: .answer)"))
        #expect(exchange.contains("waitForOutboundSendCompletion"))
        #expect(notifications.contains("markIceConnectedOrCompleted"))
        let groupCall = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+GroupCall.swift"
            ),
            encoding: .utf8
        )
        #expect(groupCall.contains("beginOutboundSendWait(matching: .offer)"))
        #expect(groupCall.contains("waitForOutboundSendCompletion"))
        #expect(!exchange.contains("Each candidate send is a ratchet-encrypt round trip"))
    }

    @Test("outbound send stays FIFO so candidates never jump ahead of SDP")
    func outboundSendStaysFIFO() {
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.offer],
            incomingFlag: .candidate) == 1)
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.candidate, .candidate],
            incomingFlag: .mediaReady) == 2)
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.offer, .candidate],
            incomingFlag: .answer) == 2)
    }
}
