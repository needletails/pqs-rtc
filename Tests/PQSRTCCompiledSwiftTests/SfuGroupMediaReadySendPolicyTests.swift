import Foundation
import Testing
@testable import PQSRTC

@Suite("SFU group mediaReady send")
struct SfuGroupMediaReadySendPolicyTests {
    @Test("shared call-control actor must not wait for the sibling mediaReady write")
    func callControlActorMustNotWaitForSiblingWrite() {
        #expect(!SfuGroupMediaReadySendPolicy.shouldAwaitMediaReadySendOnCallingStack(
            calledFromSharedCallControlActor: true
        ))
    }

    @Test("off-actor caller may wait for the mediaReady write")
    func offActorCallerMayWait() {
        #expect(SfuGroupMediaReadySendPolicy.shouldAwaitMediaReadySendOnCallingStack(
            calledFromSharedCallControlActor: false
        ))
    }

    @Test("sendSfuGroupMediaReady feeds then leaves the wait off the calling stack")
    func sendDoesNotWaitOnCallingStack() throws {
        let groupCall = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        let send = try SourceContract.sourceBody(of: "sendSfuGroupMediaReady", in: groupCall)
        #expect(send.contains("SfuGroupMediaReadySendPolicy.shouldAwaitMediaReadySendOnCallingStack"))
        #expect(send.contains("calledFromSharedCallControlActor: true"))
        #expect(send.contains("beginOutboundSendWait(matching: .mediaReady)"))
        #expect(send.contains("feedTask"))
        #expect(send.contains("finishSfuGroupMediaReadySend"))
        #expect(send.contains("Queued SFU group mediaReady send off calling stack"))
        #expect(!send.contains("waitForOutboundSendCompletion"))
        #expect(!send.contains("Task.sleep"))
    }

    @Test("mediaReady send settlement waits after call-control can return")
    func sendSettlementWaitsOffCallingStack() throws {
        let groupCall = try source("Sources/PQSRTC/RTCSession+GroupCall.swift")
        let finish = try SourceContract.sourceBody(of: "finishSfuGroupMediaReadySend", in: groupCall)
        #expect(finish.contains("waitForOutboundSendCompletion"))
        #expect(finish.contains("confirmedSfuGroupMediaReadyKeys"))
        #expect(finish.contains("Sent SFU group media readiness"))
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
