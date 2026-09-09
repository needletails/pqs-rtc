import Foundation
import Testing
@testable import PQSRTC

@Suite("Unanswered group mediaReady resend")
struct UnansweredGroupMediaReadyResendPolicyTests {
    @Test("flat inbound after a lost first mediaReady may resend once")
    func flatInboundResendsOnce() {
        #expect(UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: false))
    }

    @Test("missing source key must not resend")
    func missingSourceKeyDoesNotResend() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: false,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: false))
    }

    @Test("a confirmed IRC PRIVMSG write must not encrypt another mediaReady")
    func confirmedWireSendDoesNotResend() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: true,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: false))
    }

    @Test("advancing inbound must not resend and clears the generation")
    func advancingIngressDoesNotResend() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: true,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: false))
        #expect(UnansweredGroupMediaReadyResendPolicy.shouldClearUnansweredResendGeneration(
            inboundFlowIsAdvancing: true))
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldClearUnansweredResendGeneration(
            inboundFlowIsAdvancing: false))
    }

    @Test("one-shot: a second flat observation does not resend")
    func alreadyResentDoesNotLoop() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: true))
    }

    @Test("an in-flight first mediaReady write must not encrypt another")
    func inFlightWireSendDoesNotResend() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: true,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: true,
            alreadyResentForCurrentReadyGeneration: false))
    }

    @Test("1:1 rooms do not use group mediaReady resend")
    func oneToOneDoesNotResend() {
        #expect(!UnansweredGroupMediaReadyResendPolicy.shouldResendUnansweredGroupMediaReady(
            isGroupOrConference: false,
            sourceKeyInstalled: true,
            inboundFlowIsAdvancing: false,
            confirmedWireSendForSource: false,
            wireSendInFlightForSource: false,
            alreadyResentForCurrentReadyGeneration: false))
    }

    @Test("mediaReady is essential outbound signaling")
    func mediaReadyIsEssentialOutboundFlag() {
        #expect(TaskProcessor.isEssentialOutboundSignalingFlag(.mediaReady))
        #expect(TaskProcessor.isEssentialOutboundSignalingFlag(.offer))
        #expect(TaskProcessor.isEssentialOutboundSignalingFlag(.answer))
        #expect(!TaskProcessor.isEssentialOutboundSignalingFlag(.candidate))
    }

    @Test("outbound send stays in encrypt order")
    func outboundSendStaysInEncryptOrder() {
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.candidate, .candidate],
            incomingFlag: .mediaReady) == 2)
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.mediaReady, .candidate],
            incomingFlag: .answer) == 2)
        #expect(TaskProcessor.outboundSendInsertIndex(
            existingFlags: [.offer],
            incomingFlag: .candidate) == 1)
    }

    @Test("Apple stall skip and sendSfuGroupMediaReady wait for the wire")
    func unansweredResendAndSendConfirmationAreWired() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ios = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Apple/Controllers/iOS/VideoCallViewController+UIKit.swift"
            ),
            encoding: .utf8
        )
        let mac = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Apple/Controllers/macOS/VideoCallViewController+AppKit.swift"
            ),
            encoding: .utf8
        )
        let groupCall = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+GroupCall.swift"
            ),
            encoding: .utf8
        )
        let video = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/RTCSession+Video.swift"
            ),
            encoding: .utf8
        )
        #expect(ios.contains("refreshUnansweredGroupMediaReadyIfNeeded"))
        #expect(mac.contains("refreshUnansweredGroupMediaReadyIfNeeded"))
        #expect(video.contains("refreshUnansweredGroupMediaReadyIfNeeded"))
        #expect(groupCall.contains("beginOutboundSendWait"))
        #expect(groupCall.contains("waitForOutboundSendCompletion"))
        #expect(groupCall.contains("cancelOutboundSendWait"))
        #expect(groupCall.contains("resolvedChannelWireId"))
        #expect(groupCall.contains("confirmedSfuGroupMediaReadyKeys"))
        #expect(groupCall.contains("pendingSfuGroupMediaReadyKeys"))
        #expect(video.contains("confirmedWireSendForSource"))
        #expect(video.contains("wireSendInFlightForSource"))
        #expect(!video.contains("Task.sleep"))
        #expect(!groupCall.contains("Task.sleep"))
    }
}
