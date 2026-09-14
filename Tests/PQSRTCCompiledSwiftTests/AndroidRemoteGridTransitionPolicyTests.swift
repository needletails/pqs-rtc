import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidRemoteGridTransitionPolicyTests {
    @Test("1-up ↔ N-up locks native scale before publishing visible views")
    func countChangeAppliesNativeLayoutBeforePublishingVisibleViews() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldApplyNativeGridLayoutBeforePublishingVisibleViews(
            previousVisibleCount: 1,
            nextVisibleCount: 2
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldApplyNativeGridLayoutBeforePublishingVisibleViews(
            previousVisibleCount: 2,
            nextVisibleCount: 1
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldApplyNativeGridLayoutBeforePublishingVisibleViews(
            previousVisibleCount: 2,
            nextVisibleCount: 2
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldApplyNativeGridLayoutBeforePublishingVisibleViews(
            previousVisibleCount: 0,
            nextVisibleCount: 1
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldBumpComposeLayoutGenerationOnVisibleCountChange(
            previousVisibleCount: 2,
            nextVisibleCount: 1
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldBumpComposeLayoutGenerationOnVisibleCountChange(
            previousVisibleCount: 1,
            nextVisibleCount: 2
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldBumpComposeLayoutGenerationOnVisibleCountChange(
            previousVisibleCount: 2,
            nextVisibleCount: 2
        ))
    }

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

    @Test("in-flight episode skips unchanged tilesDidChange publishes")
    func inFlightEpisodeSkipsUnchangedTilesDidChange() {
        #expect(AndroidRemoteGridTransitionPolicy.shouldSkipRemoteTilesDidChangeDuringInFlightEpisode(
            episodeInFlight: true,
            previousSignature: "0:mm26|1:nudge",
            nextSignature: "0:mm26|1:nudge"
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldSkipRemoteTilesDidChangeDuringInFlightEpisode(
            episodeInFlight: true,
            previousSignature: "0:nudge",
            nextSignature: "0:mm26|1:nudge"
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldSkipRemoteTilesDidChangeDuringInFlightEpisode(
            episodeInFlight: false,
            previousSignature: "0:nudge",
            nextSignature: "0:nudge"
        ))
        #expect(!AndroidRemoteGridTransitionPolicy.shouldSkipRemoteTilesDidChangeDuringInFlightEpisode(
            episodeInFlight: true,
            previousSignature: "",
            nextSignature: ""
        ))
    }

    @Test("overlapping visible-grid refreshes drop stale generations")
    func overlappingVisibleGridRefreshDropsStaleGeneration() {
        let first = AndroidRemoteGridTransitionPolicy.nextVisibleRemoteRefreshGeneration(current: 0)
        let second = AndroidRemoteGridTransitionPolicy.nextVisibleRemoteRefreshGeneration(current: first)
        #expect(first == 1)
        #expect(second == 2)
        #expect(!AndroidRemoteGridTransitionPolicy.shouldCommitVisibleRemoteRefresh(
            startedGeneration: first,
            currentGeneration: second
        ))
        #expect(AndroidRemoteGridTransitionPolicy.shouldCommitVisibleRemoteRefresh(
            startedGeneration: second,
            currentGeneration: second
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

    @Test("1-up leftover uses fillMaxSize outside the 16:9 Column/Row")
    func composeUsesDedicatedSoloFullscreenBranch() throws {
        let compose = try source(
            "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
        )
        #expect(compose.contains("let tileModifier"))
        #expect(compose.contains("} else if itemCount == 1 {"))
        #expect(compose.contains("gridItemCount: itemCount"))
        #expect(compose.contains("shouldBumpComposeLayoutGenerationOnVisibleCountChange"))
        #expect(!compose.contains("// Solo conference tile keeps the full-bleed layout."))
    }

    @Test("N-up conference tiles use Apple-matching Compose chrome outside the hole-punch")
    func conferenceTilesUseComposeRoundedBorderOutsideHolePunch() throws {
        let compose = try source(
            "Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift"
        )
        let native = try source(
            "Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt"
        )
        #expect(compose.contains("let showTileChrome = gridItemCount > 1 && !enablesPipDrag && cornerRadiusDp > 0"))
        #expect(compose.contains("Color.White.copy(alpha: Float(0.12))"))
        #expect(compose.contains("Modifier.fillMaxSize().padding(conferenceTileBorderWidthDp.dp)"))
        #expect(compose.contains("conferenceTileBorderWidthDp"))
        #expect(!compose.contains("setCornerRadius"))
        #expect(!compose.contains("setZOrderMediaOverlay"))
        #expect(!native.contains("SurfaceView.setCornerRadius"))
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
        #expect(refresh.contains("AndroidRemoteGridTransitionPolicy.nextVisibleRemoteRefreshGeneration"))
        #expect(refresh.contains("AndroidRemoteGridTransitionPolicy.shouldCommitVisibleRemoteRefresh"))
        #expect(refresh.contains("AndroidRemoteGridTransitionPolicy.shouldBumpComposeLayoutGenerationOnVisibleCountChange"))
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
        let reattach = try SourceContract.sourceBody(
            of: "reattachAssignedParticipantVideoIfNeeded",
            in: controller
        )
        #expect(reattach.contains("assignedVisibleCount: participantViewAssignments.count"))
        #expect(!reattach.contains("Task.sleep"))
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
        #expect(visible.contains("allowWaitingSlot"))
        #expect(visible.contains("hasPublishedAssignedRemote"))
        #expect(compose.contains("displayedRemoteCaptureViewsForBody"))
        #expect(!visible.contains("rosterRemoteSlotCount"))
        #expect(!visible.contains("effectiveRemoteCount"))
        #expect(!visible.contains(".prefix(slotCount)"))
        #expect(compose.contains("statusBarsPadding()"))
        #expect(compose.contains("WindowInsetsCompat.Type.statusBars()"))
        #expect(compose.contains("rememberedStatusTopDp"))
        #expect(compose.contains("itemCount == 1"))
        #expect(compose.contains("rendererSlotKey &* 31 &+ 2"))
        #expect(compose.contains("applySoloFullscreenLayout()"))
        #expect(compose.contains("applyConferenceGridLayout()"))
        #expect(compose.contains("applyConferenceLetterboxForComposeTile"))
        #expect(compose.contains("view.surfaceViewRenderer.width"))
        #expect(compose.contains("Do not call `remoteCameraHostContainer` after a 16:9"))
        #expect(compose.contains("Lock conference/solo before the first host apply"))
        #expect(compose.contains("shouldApplyNativeGridLayoutBeforePublishingVisibleViews"))
        #expect(compose.contains("visibleRemoteCaptureViews = nextViews"))
        #expect(compose.contains("AndroidRemoteGridTransitionPolicy.composeGridIdentity"))
        #expect(AndroidRemoteGridTransitionPolicy.composeTileKey(
            rendererIdentity: 42,
            itemCount: 1
        ) == AndroidRemoteGridTransitionPolicy.composeTileKey(
            rendererIdentity: 42,
            itemCount: 2
        ))
        #expect(AndroidRemoteGridTransitionPolicy.composeGridIdentity(
            itemCount: 1,
            prefersAspectFit: false
        ) == AndroidRemoteGridTransitionPolicy.composeGridIdentity(
            itemCount: 2,
            prefersAspectFit: true
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
