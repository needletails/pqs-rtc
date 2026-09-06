import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct ScreenShareLayoutTransitionPolicyTests {
    @Test("local-only screen sharing does not begin remote participant reconciliation")
    func localOnlyShareDoesNotBeginRemoteReconcile() {
        #expect(
            ScreenShareLayoutTransitionPolicy.shouldBeginLayoutReconcile(remote: false, local: true) == false
        )
        #expect(
            ScreenShareLayoutTransitionPolicy.shouldBeginLayoutReconcile(remote: true, local: false)
        )
        #expect(
            ScreenShareLayoutTransitionPolicy.shouldBeginLayoutReconcile(remote: true, local: true)
        )
    }

    @Test("empty expected set settles immediately")
    func emptyExpectedSetSettlesImmediately() {
        #expect(ScreenShareLayoutTransitionPolicy.shouldSettleImmediately(expectedIdentities: []))
        let settled = ScreenShareLayoutTransitionPolicy.beginTransition(
            state: .idle,
            isStartingShare: true,
            expectedIdentities: []
        )
        #expect(settled.phase == .active)
        #expect(settled.expectedIdentities.isEmpty)
        #expect(settled.isAwaitingLayout == false)
    }

    @Test("page and roster changes replace expected set under a new generation")
    func pageAndRosterChangesReplaceExpectedSet() {
        let started = ScreenShareLayoutTransitionPolicy.beginTransition(
            state: .idle,
            isStartingShare: true,
            expectedIdentities: ["a", "b"]
        )
        let paged = ScreenShareLayoutTransitionPolicy.replacingExpectedIdentities(
            state: started,
            newIdentities: ["c", "d"]
        )
        #expect(paged.generation == started.generation &+ 1)
        #expect(paged.expectedIdentities == ["c", "d"])
        #expect(paged.reportedIdentities.isEmpty)
    }

    @Test("a report for generation N cannot settle pending generation N+1")
    func staleGenerationCannotSettleNewerPending() {
        let first = ScreenShareLayoutTransitionPolicy.beginTransition(
            state: .idle,
            isStartingShare: true,
            expectedIdentities: ["tile-a"]
        )
        let second = ScreenShareLayoutTransitionPolicy.replacingExpectedIdentities(
            state: first,
            newIdentities: ["tile-b"]
        )
        #expect(
            ScreenShareLayoutTransitionPolicy.shouldAcceptSurfaceReport(
                capturedGeneration: first.generation,
                identity: "tile-b",
                state: second
            ) == false
        )
        let afterStale = ScreenShareLayoutTransitionPolicy.applyingSurfaceReport(
            capturedGeneration: first.generation,
            identity: "tile-b",
            state: second
        )
        #expect(afterStale.phase == second.phase)
        #expect(afterStale.isAwaitingLayout)
        let afterCurrent = ScreenShareLayoutTransitionPolicy.applyingSurfaceReport(
            capturedGeneration: second.generation,
            identity: "tile-b",
            state: second
        )
        #expect(afterCurrent.phase == .active)
        #expect(afterCurrent.isAwaitingLayout == false)
    }

    @Test("stop reconcile reason is post-expand settlement not immediate reattach")
    func stopReconcileReasonIsPostExpandSettlement() {
        #expect(
            ScreenShareLayoutTransitionPolicy.stopReconcileReason(afterPostExpandSettlement: false) == nil
        )
        #expect(
            ScreenShareLayoutTransitionPolicy.stopReconcileReason(afterPostExpandSettlement: true)
                == ScreenShareLayoutTransitionPolicy.stopLayoutReattachReason
        )
    }

    @Test("Compose layout wait is not keyed by local share and stop is not immediate reattach")
    func productionStopAndComposeWaitSourceLocks() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compose = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
            ),
            encoding: .utf8
        )
        #expect(!compose.contains("\"\\(isScreenSharing)-\\(hasActiveRemoteScreenShare)\""))

        let controller = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
            ),
            encoding: .utf8
        )
        let stopBody = try sourceBody(of: "handleRemoteScreenTrackEvent", in: controller)
        #expect(!stopBody.contains("reattachParticipantVideoAfterScreenShareStopLayoutChange"))
        let settleBody = try sourceBody(
            of: "performParticipantVideoReconcileAfterScreenShareLayoutChange",
            in: controller
        )
        #expect(settleBody.contains("screen-share-stop-layout-reattach"))
        #expect(settleBody.contains("ignoreSfuDeferForSurfaceLayoutRecovery: true"))
    }

    private func sourceBody(of functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let start = source.range(of: marker) else {
            throw SourceGuardError.missingFunction(functionName)
        }
        let suffix = source[start.lowerBound...]
        guard let openingBrace = suffix.firstIndex(of: "{") else {
            throw SourceGuardError.missingFunction(functionName)
        }
        var depth = 0
        for index in suffix.indices[openingBrace...] {
            switch suffix[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[...index])
                }
            default:
                break
            }
        }
        throw SourceGuardError.missingFunction(functionName)
    }

    private enum SourceGuardError: Error {
        case missingFunction(String)
    }
}
