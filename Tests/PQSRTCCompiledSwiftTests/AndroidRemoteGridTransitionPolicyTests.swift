import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidRemoteGridTransitionPolicyTests {
    @Test("slot-count change with live tiles waits for Compose layout")
    func slotCountChangeWaitsForComposeLayout() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: 1,
            nextVisibleCount: 2
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: 2,
            nextVisibleCount: 3
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: 2,
            nextVisibleCount: 1
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: 0,
            nextVisibleCount: 2
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach(
            previousVisibleCount: 2,
            nextVisibleCount: 2
        ))
    }

    @Test("assignment into an unchanged grid reattaches immediately")
    func unchangedSlotCountReattachesOnSignatureChange() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 2,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:-",
            nextSignature: "0:echo|1:nudge"
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 2,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:nudge",
            nextSignature: "0:echo|1:nudge"
        ))
    }

    @Test("1-to-2 grid resize does not reattach before Compose reports the new size")
    func slotCountChangeDoesNotReattachImmediately() {
        #expect(!AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 1,
            nextVisibleCount: 2,
            previousSignature: "0:echo|1:-",
            nextSignature: "0:echo|1:nudge"
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 1,
            nextVisibleCount: 2,
            previousSignature: "0:echo",
            nextSignature: "0:echo"
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 2,
            nextVisibleCount: 1,
            previousSignature: "0:echo|1:nudge",
            nextSignature: "0:echo"
        ))
    }

    @Test("first mount still reattaches when the slot count appears")
    func firstMountReattachesImmediately() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately(
            previousVisibleCount: 0,
            nextVisibleCount: 2,
            previousSignature: "",
            nextSignature: "0:-|1:-"
        ))
    }

    @Test("host must not reset AndroidVideoCallView identity when remoteCount changes")
    func remoteCountMustNotResetVideoCallViewIdentity() {
        #expect(!AndroidRemoteGridTransitionPolicy.shouldResetVideoCallViewIdentityOnRemoteCountChange())
    }

    @Test("hangup onDisappear tears down LocalPreview even while callState is still Connected")
    func hangupDisappearTearsDownAfterChromeHidPreview() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldTeardownRenderersOnDisappear(
            didEnterLiveCall: true,
            showsLocalPreview: false,
            endedCall: false,
            isTerminalCallState: false,
            isIdleAfterLiveCall: false
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldTeardownRenderersOnDisappear(
            didEnterLiveCall: true,
            showsLocalPreview: true,
            endedCall: false,
            isTerminalCallState: false,
            isIdleAfterLiveCall: false
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldTeardownRenderersOnDisappear(
            didEnterLiveCall: true,
            showsLocalPreview: true,
            endedCall: false,
            isTerminalCallState: false,
            isIdleAfterLiveCall: true
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldTeardownRenderersOnDisappear(
            didEnterLiveCall: false,
            showsLocalPreview: false,
            endedCall: false,
            isTerminalCallState: false,
            isIdleAfterLiveCall: false
        ))
    }

    @Test("grid-slot reports settle only after every expected tile posts the new generation")
    func gridSlotReportsSettleOnMatchingGeneration() {
        let started = AndroidRemoteGridTransitionPolicy.beginGridSlotTransition(
            state: .idle,
            expectedIdentities: ["echo", "nudge"]
        )
        #expect(started.isAwaiting)
        #expect(started.generation > 0)

        #expect(!AndroidRemoteGridTransitionPolicy.shouldAcceptGridSlotSurfaceReport(
            capturedGeneration: started.generation,
            identity: "missing",
            state: started
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldAcceptGridSlotSurfaceReport(
            capturedGeneration: started.generation &- 1,
            identity: "echo",
            state: started
        ))

        let afterEcho = AndroidRemoteGridTransitionPolicy.applyingGridSlotSurfaceReport(
            capturedGeneration: started.generation,
            identity: "echo",
            state: started
        )
        #expect(afterEcho.isAwaiting)

        let afterBoth = AndroidRemoteGridTransitionPolicy.applyingGridSlotSurfaceReport(
            capturedGeneration: started.generation,
            identity: "nudge",
            state: afterEcho
        )
        #expect(!afterBoth.isAwaiting)
        #expect(afterBoth.expectedIdentities.isEmpty)
    }

    @Test("empty expected set settles immediately")
    func emptyExpectedSetSettlesImmediately() {
        let settled = AndroidRemoteGridTransitionPolicy.beginGridSlotTransition(
            state: .idle,
            expectedIdentities: []
        )
        #expect(!settled.isAwaiting)
        #expect(settled.generation > 0)
    }

    @Test("Compose uses one ConferenceTile call site for 1-up and N-up")
    func composeUsesSingleConferenceTileCallSite() throws {
        let compose = try source(
            "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
        )
        #expect(compose.contains("let tileModifier"))
        #expect(!compose.contains("// Solo conference tile keeps the full-bleed layout."))
        #expect(!compose.contains("if itemCount == 1 {\n                                        ConferenceTile("))
    }

    @Test("grid refresh waits for Compose layout instead of immediate reattach on slot change")
    func gridRefreshWiresComposeLayoutWait() throws {
        let compose = try source(
            "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
        )
        let refresh = try SourceContract.sourceBody(
            of: "refreshVisibleRemoteCaptureViews",
            in: compose
        )
        #expect(refresh.contains("AndroidRemoteGridTransitionPolicy.shouldWaitForComposeLayoutBeforeReattach"))
        #expect(refresh.contains("beginParticipantVideoReconcileAfterGridSlotLayoutChange"))
        #expect(refresh.contains("AndroidRemoteGridTransitionPolicy.shouldReattachAssignedTilesImmediately"))
        #expect(!refresh.contains("Task.sleep"))
    }

    @Test("controller settles grid-slot transitions from participantSurfaceDidUpdateLayout")
    func controllerSettlesGridSlotFromComposeLayoutEvent() throws {
        let controller = try source(
            "Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift"
        )
        #expect(controller.contains("func beginParticipantVideoReconcileAfterGridSlotLayoutChange"))
        let surface = try SourceContract.sourceBody(
            of: "participantSurfaceDidUpdateLayout",
            in: controller
        )
        #expect(surface.contains("AndroidRemoteGridTransitionPolicy.shouldAcceptGridSlotSurfaceReport"))
        #expect(surface.contains("reattachAssignedParticipantVideoIfNeeded"))
        #expect(!surface.contains("Task.sleep"))
    }

    @Test("visible Android slots follow assigned remotes, not channel roster")
    func composeWiresAssignedOnlyGridSlotCount() throws {
        let compose = try source(
            "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
        )
        let visible = try SourceContract.sourceBody(
            of: "multipartyRemoteCaptureViews",
            in: compose
        )
        #expect(visible.contains("assignedParticipantCount()"))
        #expect(visible.contains("assignedRemoteViews()"))
        #expect(visible.contains("AndroidMultipartyVideoLayout.multipartyGridSlotCount"))
        #expect(visible.contains("AndroidMultipartyVideoLayout.mountedRemoteViews"))
        #expect(!visible.contains("rosterRemoteSlotCount"))
        #expect(!visible.contains("effectiveRemoteCount"))
        #expect(!visible.contains(".prefix(slotCount)"))
        #expect(compose.contains("statusBarsPadding()"))
        #expect(compose.contains("WindowInsetsCompat.Type.statusBars()"))
        #expect(compose.contains("rememberedStatusTopDp"))
        #expect(compose.contains("itemCount == 1"))
        #expect(compose.contains("rendererSlotKey &* 31 &+ 2"))
        #expect(compose.contains("applySoloFullscreenLayout()"))
        #expect(AndroidRemoteGridTransitionPolicy.composeTileKey(
            rendererIdentity: 42,
            itemCount: 1
        ) != AndroidRemoteGridTransitionPolicy.composeTileKey(
            rendererIdentity: 42,
            itemCount: 2
        ))
    }

    @Test("conference host does not remount AndroidVideoCallView when remoteCount changes")
    func conferenceHostDoesNotRemountOnRemoteCount() throws {
        let conference = try appSource(
            "Sources/Nudge/Views/Conference/ConferenceCallView.swift"
        )
        #expect(!conference.contains(".id(remoteParticipantCount)"))
        #expect(conference.contains("WindowInsetsCompat.Type.statusBars()"))
        #expect(conference.contains("rememberedStatusTopDp"))
        #expect(conference.contains("last non-zero inset"))
        #expect(AndroidRemoteGridTransitionPolicy.shouldResetVideoCallViewIdentityOnRemoteCountChange() == false)
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func appSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/nudge-app")
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
