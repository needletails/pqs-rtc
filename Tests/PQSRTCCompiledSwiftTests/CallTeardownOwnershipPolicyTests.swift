import Foundation
import Testing
@testable import PQSRTC

@Suite("Call teardown ownership")
struct CallTeardownOwnershipPolicyTests {
    @Test("same-room rejoin skips leftover shutdown")
    func sameRoomRejoinSkipsLeftoverShutdown() {
        let room = "f272c4d1-5d6f-46d5-85a0-b8002a756f00"
        #expect(CallTeardownOwnershipPolicy.shouldSkipShutdownForLiveAttempt(
            endingCallId: UUID(),
            liveCallId: UUID(),
            endingRoomId: room,
            liveRoomId: room
        ))
        #expect(CallTeardownOwnershipPolicy.shouldSkipShutdownForLiveAttempt(
            endingCallId: UUID(),
            liveCallId: UUID(),
            endingRoomId: "#testing_\(room)",
            liveRoomId: "testing_\(room)"
        ))
    }

    @Test("same attempt still shuts down")
    func sameAttemptStillShutsDown() {
        let id = UUID()
        let room = "room-a"
        #expect(!CallTeardownOwnershipPolicy.shouldSkipShutdownForLiveAttempt(
            endingCallId: id,
            liveCallId: id,
            endingRoomId: room,
            liveRoomId: room
        ))
    }

    @Test("different room leftover still shuts down")
    func differentRoomLeftoverStillShutsDown() {
        #expect(!CallTeardownOwnershipPolicy.shouldSkipShutdownForLiveAttempt(
            endingCallId: UUID(),
            liveCallId: UUID(),
            endingRoomId: "room-a",
            liveRoomId: "room-b"
        ))
    }

    @Test("stale app teardown does not run for same-room rejoin")
    func staleAppTeardownDoesNotRunForSameRoomRejoin() {
        #expect(!CallTeardownOwnershipPolicy.shouldApplyStaleAppTeardown(
            currentAttemptDiffers: true,
            currentSharesRoomWithCleanup: true
        ))
        #expect(CallTeardownOwnershipPolicy.shouldApplyStaleAppTeardown(
            currentAttemptDiffers: true,
            currentSharesRoomWithCleanup: false
        ))
        #expect(CallTeardownOwnershipPolicy.shouldApplyStaleAppTeardown(
            currentAttemptDiffers: false,
            currentSharesRoomWithCleanup: true
        ))
    }

    @Test("crypto retire stays on the teardown generation")
    func cryptoRetireStaysOnTeardownGeneration() {
        #expect(CallTeardownOwnershipPolicy.shouldRetireCryptoStack(
            teardownGeneration: 3,
            liveGeneration: 3
        ))
        #expect(!CallTeardownOwnershipPolicy.shouldRetireCryptoStack(
            teardownGeneration: 3,
            liveGeneration: 4
        ))
    }

    @Test("same registered call still applies group leave")
    func sameRegisteredCallAppliesGroupLeave() {
        let id = UUID()
        #expect(CallTeardownOwnershipPolicy.shouldApplyGroupLeave(
            endingCallId: id,
            registeredCallId: id
        ))
    }

    @Test("newer registered call skips leftover group leave")
    func newerRegisteredCallSkipsLeftoverGroupLeave() {
        #expect(!CallTeardownOwnershipPolicy.shouldApplyGroupLeave(
            endingCallId: UUID(),
            registeredCallId: UUID()
        ))
    }

    @Test("production paths wait for teardown and skip same-room leftover shutdown")
    func productionPathsWaitAndSkipSameRoomLeftover() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let session = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession.swift"),
            encoding: .utf8
        )
        let shutdown = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+PeerConnection.swift"),
            encoding: .utf8
        )
        let groupCall = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+GroupCall.swift"),
            encoding: .utf8
        )
        let oneToOne = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+OneToOneCall.swift"),
            encoding: .utf8
        )
        let ice = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PQSRTC/RTCSession+IceFallback.swift"),
            encoding: .utf8
        )
        #expect(session.contains("waitForCallTeardownIfNeeded"))
        #expect(session.contains("cryptoStackGeneration"))
        #expect(session.contains("shouldRetireCryptoStack"))
        #expect(session.contains("prepareCryptoStackForNextCallIfNeeded"))
        #expect(shutdown.contains("shouldSkipShutdownForLiveAttempt"))
        #expect(shutdown.contains("waitForCallTeardownIfNeeded"))
        #expect(shutdown.contains("prepareCryptoStackForNextCallIfNeeded()"))
        #expect(shutdown.contains("resetFrameKeyProviderForHangup()"))
        #expect(groupCall.contains("waitForCallTeardownIfNeeded"))
        #expect(oneToOne.contains("waitForCallTeardownIfNeeded"))
        #expect(ice.contains("prepareCryptoStackForNextCallIfNeeded()"))

        guard let leaveRange = groupCall.range(of: "public func leave(") else {
            Issue.record("RTCSession.leave is missing")
            return
        }
        let leaveBody = String(groupCall[leaveRange.lowerBound...])
        #expect(leaveBody.contains("group.currentCall"))
        #expect(leaveBody.contains("shouldApplyGroupLeave"))
        #expect(!leaveBody.contains("callState.currentCall"))
        guard let applyRange = leaveBody.range(of: "shouldApplyGroupLeave") else {
            Issue.record("leave() does not consult shouldApplyGroupLeave")
            return
        }
        let afterApply = leaveBody[applyRange.upperBound...]
        #expect(afterApply.contains("group.leave()"))
        #expect(afterApply.contains("groupCalls.removeValue"))
        #expect(afterApply.contains("shutdown"))
        #expect(afterApply.contains("groupCalls[normalizedId] === group"))
    }
}
