import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU renegotiation answer send")
struct SfuRenegotiationAnswerSendPolicyTests {
    @Test("inbound TaskProcessor job must not wait for the sibling answer")
    func inboundJobMustNotWaitForSiblingAnswer() {
        #expect(!SfuRenegotiationAnswerSendPolicy.shouldAwaitAnswerSendOnCallingStack(
            calledFromTaskProcessorInboundJob: true
        ))
    }

    @Test("off-stack caller may wait for the answer send")
    func offStackCallerMayWait() {
        #expect(SfuRenegotiationAnswerSendPolicy.shouldAwaitAnswerSendOnCallingStack(
            calledFromTaskProcessorInboundJob: false
        ))
    }

    @Test("complete handling feeds the answer and leaves the wait off the inbound stack")
    func completeHandlingDoesNotWaitOnInboundStack() throws {
        let exchange = try source("Sources/PQSRTC/RTCSession+Exchange.swift")
        let groupCall = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        let complete = try SourceContract.sourceBody(
            of: "completeSfuRenegotiationOfferHandling",
            in: exchange
        )
        #expect(complete.contains("SfuRenegotiationAnswerSendPolicy.shouldAwaitAnswerSendOnCallingStack"))
        #expect(complete.contains("calledFromTaskProcessorInboundJob: true"))
        #expect(complete.contains("beginOutboundSendWait(matching: .answer)"))
        #expect(complete.contains("feedTask"))
        #expect(complete.contains("finishSfuRenegotiationAnswerSend"))
        #expect(!complete.contains("waitForOutboundSendCompletion"))
        #expect(!complete.contains("defer { sfuRenegotiationInFlightConnectionIds.remove"))
        #expect(groupCall.contains("completeSfuRenegotiationOfferHandling"))
    }

    @Test("answer send settlement waits after the inbound job can return")
    func answerSendSettlementWaitsOffInboundJob() throws {
        let exchange = try source("Sources/PQSRTC/RTCSession+Exchange.swift")
        let finish = try SourceContract.sourceBody(
            of: "finishSfuRenegotiationAnswerSend",
            in: exchange
        )
        #expect(finish.contains("waitForOutboundSendCompletion"))
        #expect(finish.contains("drainOrDropBufferedCandidatesAfterEssentialWire"))
        #expect(finish.contains("emitRemoteParticipantTrackRefreshAfterSfuRenegotiation"))
        #expect(finish.contains("processDeferredSfuRenegotiationOfferIfNeeded"))
        #expect(finish.contains("sfuRenegotiationInFlightConnectionIds.remove"))
        #expect(!finish.contains("Task.sleep"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
