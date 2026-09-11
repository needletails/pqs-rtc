import Foundation
import Testing

@testable import PQSRTC

@Suite(.serialized)
struct AndroidRuntimeSourceContractTests {
    @Test("installSurfaceReadyCallback removes previous callback before add")
    func installSurfaceReadyCallbackRemovesPreviousBeforeAdd() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("holder.removeCallback(previous)"))
        #expect(native.contains("installedSurfaceCallbacks"))
        #expect(native.contains("holder.addCallback(callback)"))
    }

    @Test("foreground reconcile no-ops when the call has ended")
    func reconcileVideoSurfacesAfterAppForegroundNoopsWhenEnded() throws {
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        let body = try SourceContract.sourceBody(
            of: "reconcileVideoSurfacesAfterAppForeground",
            in: controller
        )
        #expect(body.contains("isCallActiveForSurfaceUnhide()"))
    }

    /// PQSRTC is a Skip `mode: native` module. `#if SKIP` inside a compiled Swift body is
    /// always false, so Kotlin `AndroidCallChromeNativeSupport` calls placed there never run
    /// (Device3 20:29–20:33: `hit layer attached` with no detach, no `reset key=`, no
    /// `detached all call chrome overlays`). Compiled code must go through the transpiled
    /// `AndroidCallChromeBridge`.
    @Test("compiled Swift reaches call-chrome Kotlin only through AndroidCallChromeBridge")
    func compiledSwiftUsesCallChromeBridge() throws {
        let compose = try source("Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift")
        // The transpiled ContentComposer region ends at the first top-level `#endif` after
        // `#if SKIP`; everything after it is compiled Swift.
        let lines = compose.components(separatedBy: "\n")
        var depth = 0
        var skipRegionEnd: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                depth += 1
                continue
            }
            if trimmed.hasPrefix("#endif") {
                depth -= 1
                if depth == 1, skipRegionEnd == nil, index > 0 {
                    skipRegionEnd = index
                }
            }
        }
        let compiledRegion = try #require(skipRegionEnd.map { lines[$0...].joined(separator: "\n") })
        #expect(!compiledRegion.contains("AndroidCallChromeNativeSupport."))
        #expect(!compiledRegion.contains("#if SKIP"))
        #expect(compiledRegion.contains("AndroidCallChromeBridge.detachAllForCallEnd()"))
        #expect(compiledRegion.contains("AndroidCallChromeBridge.attachLocalPreviewDrag("))
        #expect(compiledRegion.contains("AndroidCallChromeBridge.setInAppPipTapHandler("))
        #expect(compiledRegion.contains("AndroidCallChromeBridge.setTileTapHandler("))

        let preview = try source("Sources/PQSRTC/Views/Android/AndroidPreviewCaptureView.swift")
        #expect(preview.contains("public struct AndroidCallChromeBridge"))
        #expect(preview.contains("public static func detachAllForCallEnd()"))
        #expect(preview.contains("public static func resetDrag(key: String)"))
        #expect(preview.contains("public static func detachDrag(key: String)"))
        #expect(preview.contains("public static func attachLocalPreviewDrag(captureView: AndroidPreviewCaptureView, edgeDp: Float) -> Bool"))
        #expect(preview.contains("public static func attachRemotePipDrag(captureView: AndroidSampleCaptureView, edgeDp: Float) -> Bool"))
        #expect(preview.contains("public static func setInAppPipTapHandler(_ handler: (() -> Void)?)"))
        #expect(preview.contains("public static func setTileTapHandler(key: String, handler: (() -> Void)?)"))
    }

    @Test("hangup disappear tears down LocalPreview when chrome already hid the PiP")
    func hangupDisappearTearsDownLocalPreviewWhenChromeHidPip() throws {
        let compose = try source("Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift")
        let body = try SourceContract.sourceBody(
            of: "teardownCallVideoResourcesIfNeeded",
            in: compose
        )
        #expect(body.contains("shouldTeardownRenderersOnDisappear"))
        #expect(body.contains("showsLocalPreview"))
        #expect(body.contains("releaseAllVideoRenderers()"))
        #expect(body.contains("abortAttachWorkForCallEnd()"))
        #expect(!body.contains("Task { @MainActor in"))
        #expect(compose.contains("AndroidCallChromeBridge.detachAllForCallEnd()"))
        let chrome = try source("Sources/PQSRTC/Skip/AndroidCallChromeNativeSupport.kt")
        #expect(chrome.contains("fun detachAllForCallEnd()"))
        #expect(chrome.contains("detached all call chrome overlays"))
        #expect(chrome.contains("OnHierarchyChangeListener"))
        #expect(chrome.contains("bringHitLayerToFrontIfNeeded"))
        #expect(!chrome.contains("addOnGlobalLayoutListener"))
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("renderedFrameObserver = null"))
        #expect(native.contains("firstFrameNotePosted"))
        #expect(native.contains("Do not post every remote"))
        #expect(!native.contains("YuvHelper.I420Rotate"))
        #expect(native.contains("if (released) return"))
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        #expect(controller.contains("createPreviewView skipped: controller already ended"))
        #expect(controller.contains("createPreviewView skipped: local preview already bound"))
        #expect(controller.contains("createSampleView skipped: controller already ended"))
        #expect(controller.contains("GroupSfuVideoAttachPolicy.shouldSurfaceParticipantCameraTile"))
        #expect(controller.contains("GroupSfuVideoAttachPolicy.episodeParticipantIdsAfterRefresh"))
        #expect(controller.contains("Releasing departed Android remote tile"))
        #expect(!controller.contains("participant still in roster"))
        #expect(controller.contains("Ignoring coordinator request; already in-flight"))
        #expect(controller.contains("shouldForceReleaseAssignmentAfterTrackRemoved"))
        #expect(controller.contains("explicitlyDeparted"))
        #expect(controller.contains("departedParticipantKeysWithoutMappedCamera"))
        #expect(controller.contains("shouldClearExplicitlyDepartedOnTrackAdded"))
        #expect(controller.contains("shouldRememberDepartedOnTrackRemoved"))
        #expect(controller.contains("Skipping Android remote camera attach; participant departed"))
        #expect(controller.contains("clearExplicitlyDepartedOnLiveCameraRejoinIfNeeded"))
        #expect(controller.contains("Cleared departed Android remote tile after live camera rejoin"))
        #expect(controller.contains("shouldQueueCoordinatorRerunWhileInFlight"))
        #expect(controller.contains("Queued coordinator rerun; participant set grew while in-flight"))
        #expect(controller.contains("shouldDeferEpisodeClearAfterStabilization"))
        #expect(controller.contains("rejoined participant not settled"))
        #expect(!controller.contains("if hasMappedCamera {\n            departedParticipantKeysWithoutMappedCamera.remove"))
        #expect(controller.contains("shouldClearSettledPostRenegotiationEpisode"))
        #expect(controller.contains("shouldQueuePendingLiveWrapperRebindAfterSettledSkip"))
        #expect(controller.contains("forceApply: true"))
        #expect(!controller.contains("until stale wrapper stalls"))
        #expect(native.contains("never wait for tail frames on a dead Java wrapper"))
        #expect(native.contains("fun applySoloFullscreenLayout()"))
        #expect(native.contains("fun applyConferenceGridLayout()"))
        #expect(native.contains("fun applyConferenceLetterboxForComposeTile"))
        #expect(native.contains("fun setRemoteCameraLayoutLock"))
        #expect(native.contains("LAYOUT_LOCK_CONFERENCE"))
        #expect(native.contains("fun clearRemoteCameraScaleLayoutCache"))
        #expect(native.contains("Conference leftover must not SCALE_ASPECT_FILL"))
        #expect(native.contains("Host is still 0×0. Do not SCALE_ASPECT_FILL"))
        #expect(native.contains("Do not guess from renderer size or display metrics"))
        #expect(native.contains("shouldApplyRemoteCameraScale"))
        #expect(!compose.contains(".frame(width: geo.size.width, height: geo.size.height)"))
    }

    @Test("post-SFU rejoin episode clears departed and defers in-flight stabilize clear")
    func postSfuRejoinEpisodeClearsDepartedAndDefersInFlightClear() throws {
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        let episode = try SourceContract.sourceBody(
            of: "handlePostRenegotiationAttachEpisode",
            in: controller
        )
        #expect(episode.contains("clearExplicitlyDepartedOnLiveCameraRejoinIfNeeded"))
        #expect(episode.contains("shouldQueueCoordinatorRerunWhileInFlight"))
        #expect(episode.contains("Queued coordinator rerun; participant set grew while in-flight"))
        #expect(!episode.contains("Ignoring coordinator request; already in-flight"))
        let finalize = try SourceContract.sourceBody(
            of: "finalizePostRenegotiationAttachEpisode",
            in: controller
        )
        #expect(finalize.contains("shouldDeferEpisodeClearAfterStabilization"))
        #expect(finalize.contains("rejoined participant not settled"))
        #expect(finalize.contains("coordinatorAttachParticipantIds"))
        let clearDeparted = try SourceContract.sourceBody(
            of: "clearExplicitlyDepartedOnLiveCameraRejoinIfNeeded",
            in: controller
        )
        #expect(clearDeparted.contains("shouldClearExplicitlyDepartedOnTrackAdded"))
        #expect(clearDeparted.contains("androidRemoteCameraParticipantWasPruned"))
        #expect(!clearDeparted.contains("Task.sleep"))
    }

    @Test("coalesced attach after markCallEndedLocally is a no-op")
    func coalescedAttachAfterMarkCallEndedLocallyIsNoOp() throws {
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        let attach = try SourceContract.sourceBody(of: "performParticipantVideoAttach", in: controller)
        #expect(attach.contains("shouldRunCoalescedParticipantAttach"))
        #expect(controller.contains("func shouldRunCoalescedParticipantAttach"))
        let ended = try SourceContract.sourceBody(of: "markCallEndedLocally", in: controller)
        #expect(ended.contains("participantVideoAttachLifecycleGeneration &+= 1"))
        #expect(controller.contains("func abortAttachWorkForCallEnd()"))
        let stop = try SourceContract.sourceBody(of: "stop()", in: controller)
        #expect(stop.contains("abortAttachWorkForCallEnd()"))
        #expect(stop.contains("tearDownHostedMediaIfNeeded()"))
        let abort = try SourceContract.sourceBody(of: "abortAttachWorkForCallEnd", in: controller)
        #expect(abort.contains("attachWorkAborted = true"))
        #expect(abort.contains("cancelPostRenegotiationAttachCoordinator()"))
        #expect(!abort.contains("Task.sleep"))
    }

    @Test("idle pool slots do not reinitialize EGL on layout")
    func idlePoolSlotsDoNotReinitializeEglOnLayout() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("egl_reinit_idle_pool_slot_skipped"))
        #expect(native.contains("egl_init_idle_pool_factory_skipped"))
        #expect(native.contains("object SendTextureAppearanceSoftener"))
        #expect(native.contains("fun applyTransformMatrix("))
        #expect(native.contains("peerConnectionInitializationOptions"))
        #expect(native.contains("Logging.Severity.LS_WARNING"))
        #expect(native.contains("fun isBenignWebRtcWarning"))
        #expect(native.contains("RED codec with no associated codecs"))
        #expect(native.contains("Delta value too large"))
        #expect(native.contains("fun invalidateAndRefresh()"))
        #expect(native.contains("Never EGL-reinit inside OnLayout"))
        #expect(native.contains("attachPosted = true"))
        #expect(!native.contains("egl_reinit_idle_pool_slot_complete"))
    }

    @Test("rotation skips holder EGL reinit until the window matches configuration")
    func rotationSkipsHolderEglReinitUntilWindowMatches() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("surface_holder_rotation_skip"))
        #expect(native.contains("surface_holder_aspect_fit_skip"))
        #expect(native.contains("shouldAllowAttachDrivenEglReinit"))
        #expect(native.contains("egl_init_stale cannot force"))
        #expect(native.contains("isLikelyAspectFitWrapSurfaceMeasure"))
        #expect(native.contains("windowOrientationMatchesConfiguration"))
        #expect(native.contains("shouldReinitRendererEglAfterComposeLayoutSettled"))
        #expect(native.contains("shouldReinitRendererEglForImmediateHolderResize"))
        #expect(native.contains("shouldDeferAspectFitWrapContent"))
        #expect(native.contains("shouldApplyRemoteCameraScale"))
        #expect(native.contains("forceFit: Boolean"))
        #expect(native.contains("forceFit = conferenceForceFit"))
        #expect(native.contains("letterboxExactSize"))
        #expect(native.contains("shouldLetterboxSettledConferenceCell"))
        #expect(native.contains("letterboxExactSizeOrPortraitFallback"))
        #expect(native.contains("isLikelySettledSixteenByNineCell"))
        #expect(native.contains("shouldReapplyConferenceLetterboxOnSameSizeLayout"))
        #expect(native.contains("letterboxExactSizeForSettledConferenceCell"))
        #expect(native.contains("applyConferenceLetterboxForComposeTile"))
        #expect(native.contains("conferenceLetterboxFrameRotation"))
        #expect(native.contains("shouldApplyConferenceLetterboxForComposeTile"))
        #expect(native.contains("shouldKeepExistingConferenceLetterbox"))
        #expect(native.contains("shouldLetterboxConferenceSurface"))
        #expect(native.contains("shouldSkipUnchangedConferenceLetterboxApply"))
        #expect(native.contains("shouldUseRememberedSettledConferenceTile"))
        #expect(native.contains("shouldForceConferenceLetterboxExactSize"))
        #expect(native.contains("conferenceCellMatchesWindow"))
        #expect(native.contains("maybeLetterboxConferenceSurface"))
        #expect(native.contains("surface_holder_conference_letterbox"))
        #expect(native.contains("Do not treat a 16:9 Compose tile as the window")
            || native.contains("not `view.rootView`"))
        #expect(native.contains("shouldResetMatchParentWhenDeferringConferenceLetterbox"))
        #expect(native.contains("shouldDeferSoloExactLetterboxOnNonFullscreenHost"))
        #expect(native.contains("shouldAllowEglReinitWhileSurfaceNotReady"))
        #expect(native.contains("egl_reinit_skipped_surface_not_ready"))
        #expect(native.contains("shouldSkipRedundantAttachWhileSurfaceNotReady"))
        #expect(native.contains("attach_skipped_surface_not_ready_already_queued"))
        #expect(native.contains("lastAppliedDeferredFill"))
        #expect(native.contains("Same-size OnLayout must not re-apply"))
        #expect(native.contains("assignMatchParentLayoutParamsIfNeeded"))
    }

    @Test("local preview fans out from the capturer, not the send VideoTrack")
    func localPreviewFansOutFromCapturerNotVideoTrack() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        #expect(native.contains("deliverLocalPreviewCaptureFrame"))
        #expect(native.contains("addLocalPreviewCaptureSink"))
        #expect(native.contains("hasLocalPreviewCaptureSink"))
        #expect(native.contains("Bound local preview to capturer fanout"))
        #expect(native.contains("previewWantsCaptureFanout"))
        let preview = try source("Sources/PQSRTC/Views/Android/AndroidPreviewCaptureView.swift")
        #expect(preview.contains("public func hasActiveSink()"))
        #expect(!native.contains("Texture not ready, queued capturer fanout bind"))
        #expect(native.contains("disableFpsReduction"))
        #expect(native.contains("setZOrderMediaOverlay(true)"))
        #expect(native.contains("compositor=SurfaceView"))
        #expect(native.contains(": SurfaceView(context), VideoSink, SurfaceHolder.Callback"))
        #expect(!native.contains("isOpaque = false\n        surfaceTextureListener"))
        #expect(native.contains("LOCAL_CAMERA_CAPTURE_FPS = 30"))
        #expect(native.contains("fun startLocalCameraCapture("))
        #expect(native.contains("capturer.startCapture(width, height, fps)"))
        #expect(client.contains("AndroidRTCViewSupport.startLocalCameraCapture("))
        #expect(!client.contains("capturer.startCapture(Int32("))
        #expect(!client.contains("startLocalVideoCaptureIfNeeded(fps:"))
        #expect(!client.contains("startLocalVideo(fps:"))
        #expect(client.contains("CameraCaptureFrameRouter.deliver("))
        #expect(native.contains("object CameraCaptureFrameRouter"))
        #expect(native.contains("enqueueSoftenAndSend"))
        #expect(native.contains("lockOpenedCamera2ToFixedFpsIfNeeded"))
        #expect(native.contains("Locked Camera2 AE fps range to"))
        #expect(client.contains("lockOpenedCamera2ToFixedFpsIfNeeded"))
        #expect(native.contains("deliverLocalPreviewCaptureFrame(frame)"))
        #expect(!native.contains("deliverLocalPreviewCaptureFrame(upright)"))
        #expect(!native.contains("private fun uprightI420"))
        #expect(native.contains("preview=$previewKind send=$sendKind"))
        #expect(native.contains("I420Softened"))
        #expect(native.contains("isCamera2PreviewSurfaceAttached"))
        #expect(native.contains("fun attachOpenedCamera2PreviewSurfaceIfNeeded"))
        #expect(native.contains("Attached Camera2 preview surface"))
        #expect(native.contains("Do not `for (dx in -2..2)`"))
        #expect(native.contains("LOCAL_PREVIEW_PIPELINE_REVISION = \"2026-09-11-l\""))
        #expect(native.contains("shouldSkipUnchangedConferenceLetterboxApply"))
        #expect(native.contains("shouldUseRememberedSettledConferenceTile"))
        #expect(native.contains("shouldForceConferenceLetterboxExactSize"))
        #expect(native.contains("rememberedSettledConferenceTileSize"))
        #expect(native.contains("conferenceCellMatchesWindow"))
        #expect(native.contains("fragmentSource(kind, rounded = true)"))
        #expect(!native.contains("fragmentSource(kind, rounded = false)"))
        #expect(native.contains("USE_CAMERA2_PREVIEW_SURFACE = false"))
        #expect(native.contains("ANDROID_CPU_APPEARANCE_SOFTENING = false"))
        #expect(native.contains("glSoften=$glSoften"))
        #expect(native.contains("LocalPreview glSoften="))
        #expect(native.contains("sharedEgl=true compositor=SurfaceView corner=GlRoundedRect"))
        #expect(native.contains("class RoundedRectGlDrawer"))
        #expect(native.contains("holder.setFormat(PixelFormat.TRANSLUCENT)"))
        #expect(!native.contains("SurfaceControl.Transaction().setCornerRadius"))
        #expect(native.contains("Appearance softening first frame"))
        #expect(native.contains("via=GlRoundedRect"))
        #expect(native.contains("uniform float uSoften"))
        #expect(!native.contains("isolated preview EglBase"))
        #expect(native.contains("LocalPreview first frame buffer="))
        #expect(native.contains("LocalPreviewInitializing EglRenderer revision="))
        #expect(native.contains("applyOpenedCamera2Outputs revision="))
        #expect(client.contains("fanOutLocalPreview: true"))
        #expect(client.contains("fanOutLocalPreview: false"))
        // Factory init must not orphan the EglBase the PiP already shares.
        #expect(client.contains("Reusing EGL base for PeerConnectionFactory"))
        #expect(client.contains("val existingEgl = this@AndroidRTCClient.eglBase"))
        #expect(!native.contains("Attached track immediately - texture ready"))
        #expect(!native.contains("Attached pending track after texture ready"))
    }

    @Test("local preview Compose update does not re-wrap the TextureView host")
    func localPreviewComposeUpdateDoesNotRewrapHost() throws {
        let compose = try source("Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift")
        #expect(compose.contains("localPreviewHostContainer"))
        #expect(compose.contains("Do not re-wrap the SurfaceView host"))
        #expect(compose.contains("configureRoundedOutline applies GL rounded-rect on the overlay"))
        #expect(!compose.contains("GEO SIZE"))
        #expect(!compose.contains("NEW SIZE"))
    }

    @Test("conference tile layout callback is gated on a newly posted reconcile")
    func conferenceTileLayoutCallbackIsGatedOnPostedReconcile() throws {
        let compose = try source("Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift")
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(compose.contains("if view.rendererDidUpdateLayoutFromCompose()"))
        #expect(compose.contains("hasAssignedTrackForRendererInit"))
        #expect(compose.contains("conferenceTileComposeUpdateIsNoOp"))
        #expect(compose.contains("egl_init_idle_pool_factory_skipped") || native.contains("egl_init_idle_pool_factory_skipped"))
        #expect(compose.contains("shouldReplaceLocalPreviewOverlaySize"))
        #expect(compose.contains("Attach PiP drag here"))
        #expect(compose.contains("hideLocalPreviewForInAppPictureInPicture"))
        #expect(compose.contains("isLocalPreviewMinimized"))
        #expect(compose.contains("toggleLocalPreviewOverlaySize"))
        #expect(compose.contains("must not notify the controller"))
        #expect(native.contains("Missing sink is an attach event, not a layout event"))
        #expect(native.contains("if (width <= 0 || height <= 0) return false"))
    }

    @Test("post-SFU cryptor reconcile does not reattach unchanged audio")
    func postSfuCryptorReconcileDoesNotReattachUnchangedAudio() throws {
        let handler = try source("Sources/PQSRTC/RTCSession+PeerNotificationsHandler.swift")
        let body = try SourceContract.sourceBody(
            of: "reconcileAndroidReceiverFrameCryptorsAfterSfuRenegotiation",
            in: handler
        )
        #expect(!body.contains("trackKind: \"audio\""))
        let audioReconcile = try SourceContract.sourceBody(
            of: "reconcileAndroidRemoteParticipantAudioTracksAfterSetRemoteSDP",
            in: handler
        )
        #expect(audioReconcile.contains("shouldAttachAndroidSfuAudioReceiverCryptorAfterSdp"))
        #expect(audioReconcile.contains("hasLiveReceiverCryptor"))
        #expect(audioReconcile.contains("hasAudioReceiverCryptor(for:"))
        #expect(audioReconcile.contains("cryptor unchanged"))
        #expect(audioReconcile.contains("androidResolvedRemoteAudioTrackId"))
        #expect(audioReconcile.contains("attachReason = \"no live cryptor\""))
        #expect(audioReconcile.contains("androidSessionRemoteAudioResolvedTrackIdsByParticipantId") ||
                handler.contains("androidSessionRemoteAudioResolvedTrackIdsByParticipantId"))
        #expect(!audioReconcile.contains("audioTrack._isEnabled = false"))
        #expect(handler.contains("preferredAndroidDidAddReceiverParticipantLabels"))
        #expect(handler.contains("SDP reconcile owns attach"))
        let appleAudioReconcile = try SourceContract.sourceBody(
            of: "reconcileAppleRemoteParticipantAudioTracksAfterSetRemoteSDP",
            in: handler
        )
        #expect(appleAudioReconcile.contains("shouldUpgradeAppleSfuAudioMapping"))
        #expect(appleAudioReconcile.contains("wrapper changed, cryptor unchanged"))
    }

    @Test("audio cryptor factory null restores track enable")
    func holdAndroidRemoteAudioRestoresEnableWhenCryptorNull() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        #expect(native.contains("if (cryptor == null)"))
        #expect(native.contains("enableAndroidRemoteAudioReceiverTrack(receiver)"))
        #expect(native.contains("finally"))
        #expect(native.contains("shouldReuseAudioReceiverCryptorBinding"))
        #expect(native.contains("fun shouldAttachAndroidSfuAudioReceiverCryptorAfterSdp"))
        #expect(native.contains("fun hasAudioReceiverCryptor(participant: String)"))
    }

    @Test("hangup track lookup never queries native signalingState")
    func hangupTrackLookupNeverQueriesNativeSignalingState() throws {
        let native = try source("Sources/PQSRTC/Skip/AndroidRTCNativeSupport.kt")
        let client = try source("Sources/PQSRTC/Android/AndroidRTCClient.swift")
        let peer = try source("Sources/PQSRTC/RTCSession+PeerConnection.swift")
        let video = try source("Sources/PQSRTC/RTCSession+Video.swift")
        #expect(native.contains("fun markPeerConnectionRetired"))
        #expect(native.contains("!isPeerConnectionRetired(peerConnection)"))
        #expect(native.contains("Never call into WebRTC here."))
        #expect(!native.contains("when (peerConnection.signalingState())"))
        #expect(!native.contains("PeerConnection.SignalingState.CLOSED -> false"))
        #expect(client.contains("func retireCurrentNativePeerConnection()"))
        #expect(client.contains("markPeerConnectionRetired(peerConnection: peerConnectionToClose)"))
        #expect(client.contains("usablePlatformPeerConnection(for:"))
        #expect(peer.contains("rtcClient.retireCurrentNativePeerConnection()"))
        #expect(peer.contains("_ = beginEnding(connectionId: connectionIdKey)"))
        #expect(video.contains("shouldAbortAndroidRemoteCameraAttach"))
        let compose = try source("Sources/PQSRTC/Views/Android/AndroidLocalVideoCompose.swift")
        #expect(compose.contains("Releasing Android call video renderers"))
        #expect(compose.contains("AndroidCallChromeBridge.detachAllForCallEnd()"))
        #expect(compose.contains("teardownCallVideoResourcesIfNeeded"))
        let chrome = try source("Sources/PQSRTC/Skip/AndroidCallChromeNativeSupport.kt")
        #expect(chrome.contains("detached all call chrome overlays"))
        let adaptive = try source("Sources/PQSRTC/RTCSession+AndroidAdaptiveVideo.swift")
        #expect(adaptive.contains("Android adaptive video target fps="))
        #expect(adaptive.contains("essentialInFlightCount="))
        #expect(adaptive.contains("shouldYield="))
        let controller = try source("Sources/PQSRTC/Views/Android/AndroidVideoCallController.swift")
        #expect(controller.contains("publishRemoteParticipantTilesDidChangeIfNeeded"))
        #expect(controller.contains("shouldSkipRemoteTilesDidChangeDuringInFlightEpisode"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
