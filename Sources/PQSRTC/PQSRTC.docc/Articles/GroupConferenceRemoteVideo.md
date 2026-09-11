# Group/conference remote video (Apple and Android)

This article describes how PQSRTC is **designed** to deliver remote camera tiles in SFU
group/conference calls on **Apple** and **Android**. It is the reference for whether the client
API is coherent—not a collection of platform hacks.

If you are wiring signaling or E2EE first, read <doc:Group-Calls>, <doc:SFUSignalingOverview>,
and <doc:GroupSfuFrameE2EE> before this article.

## Design goals

PQSRTC group/conference video follows these invariants:

1. **One SFU PeerConnection, many remote tracks.** Each publisher appears as an inbound
   `RTCRtpReceiver` / remote video track. The SDK maps tracks to stable `participantId` values
   in ``RTCConnection/remoteVideoTracksByParticipantId``.

2. **Server-driven renegotiation only.** Group/conference SFU offers are explicit. Client code
   must not turn generic `negotiationNeeded` callbacks into extra offers (see
   <doc:SFUSignalingOverview>).

3. **Wrapper rotation is normal.** After SFU renegotiation the negotiated **track id** often
   stays the same while WebRTC replaces the underlying **platform track object** (new Java wrapper
   on Android, new Obj‑C track on Apple). Renderers bound to the old wrapper show frozen frames
   even when FrameCryptor and the connection map already point at the live receiver.

4. **Session owns the map; UI owns the sink.** ``RTCSession`` reconciles live receivers into
   `remoteVideoTracksByParticipantId`. Platform call UI attaches those tracks to per-participant
   renderers. UI must not maintain a parallel track cache that drifts from the session map.

5. **Event-driven settlement.** Attach, rebind, and recovery run on concrete state transitions:
   signaling stable, post-renegotiation episode, first rendered frame, inbound decode advancing,
   renderer frames going stale, surface layout changes. Attach policy does **not** use timer-based
   retry loops for media routing.

6. **Cross-platform policy where possible.** ``GroupSfuVideoAttachPolicy`` (in
   `AndroidMultipartyVideoLayout.swift`) defines defer/refresh rules shared by both platforms.
   Platform-specific coordinators exist only where renderer lifecycles differ (Metal vs EGL).

## End-to-end pipeline

At a high level every remote tile traverses the same stages:

```
Server SFU offer
  → RTCSession.completeSfuRenegotiationOfferHandling
  → setRemoteDescription / receiver callbacks
  → Map receiver → participantId (msid / SDP reconciliation)
  → rebind*GroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded  (session map → live wrapper)
  → emitRemoteParticipantTrackRefreshAfterSfuRenegotiation
  → Platform UI attach/rebind coordinator
  → Renderer sink (Metal or SurfaceViewRenderer)
```

### Stage 1 — Signaling and defer window

While an SFU answer is in flight or SDP signaling is not yet stable, participant renderer
attaches are deferred:

```swift
await session.shouldDeferSfuGroupParticipantVideoAttach(for: connectionId)
```

This wraps ``GroupSfuVideoAttachPolicy/shouldDeferParticipantVideoAttach(renegotiationInFlight:signalingIsStable:)``.
During defer:

- Individual ``RemoteParticipantTrackEvent`` notifications are suppressed **and queued** into
  `pendingParticipantRendererSinkRefreshByConnectionId`. Dropping them (queue omitted) leaves
  newly mapped late joiners with session tracks but no tile after settlement, because a first
  mapping whose live wrapper already matches is not a rebound.
- Renderer attaches that return during defer also enqueue the same participant ids.
- Android additionally records rebound ids until settlement.

> Important: Defer ends when renegotiation completes **and** signaling is stable—not on a timer.
> Signaling-stable also assigns any already-mapped participant who still has no tile.

### Stage 2 — Session map rebind (shared)

``RTCSession/rebindGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId:)`` (Apple)
and ``RTCSession/rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded(connectionId:)`` (Android)
walk `remoteVideoTracksByParticipantId`, resolve the **live** receiver for each participant from
the current PeerConnection + remote SDP, and update the connection map when:

- the platform track identity changed (wrapper rotation), or
- the stored track is no longer `LIVE`.

They then emit participant-scoped refresh signals. This is the **authoritative** source of which
participants need UI work after renegotiation.

``GroupSfuVideoAttachPolicy/participantIdsNeedingPostRenegotiationTileRefresh(reboundParticipantIds:queuedRefreshParticipantIds:allMappedParticipantIds:)``
selects the participant id list for the post-settlement episode: rebound wrappers **plus**
queued refresh ids (late joiners mapped while renegotiation was in flight). It does not refresh
every mapped track.

### Stage 3 — Platform UI attach

| Concern | Apple | Android |
|--------|-------|---------|
| Call UI owner | ``VideoCallViewController`` (iOS/macOS) | ``AndroidVideoCallController`` |
| Renderer | ``SampleBufferViewRenderer`` / Metal | ``AndroidSampleCaptureView`` / `SurfaceViewRenderer` |
| Post-SFU coordination | Per-participant ``RemoteParticipantTrackEvent`` + inbound-flow recovery | ``PostSfuRenegotiationAttachEpisode`` + post-renegotiation attach **coordinator** |
| Session attach API | ``RTCSession/renderRemoteVideoForParticipant(to:connectionId:participantId:)`` | Same API, targeting ``AndroidSampleCaptureView`` |

Both platforms call the same session rendering entry point; only the view type and settlement
orchestration differ.

## The wrapper-rotation problem (why this doc exists)

After SFU renegotiation you will often see logs like:

```
attachedLive=false
hasActiveSink=true
hasActiveSinkReason=attached_track_not_live_recent_frames
trackId=video_echo_<connection-uuid>   // unchanged
```

Interpretation:

| Field | Meaning |
|-------|---------|
| `trackId` | Stable negotiated id from SDP — **not** sufficient to detect live media |
| `attachedLive=false` | The Java/Obj‑C object bound to the renderer is `ENDED` |
| `hasActiveSink=true` | The renderer may still display the last frames from the dead sink |
| Live map entry | ``RTCSession`` already stores the new `LIVE` wrapper for that participant |

**Fix class:** rebind the renderer sink to the live platform track from the session map—not
reattach using a stale reference, and not infer health from `trackId` alone.

On Android, ``AndroidRemoteVideoTrackAttachPolicy/tracksShareRendererSinkSource(_:_:)`` compares
platform track identity. On Apple, renderer attachment bookkeeping uses track object identity and
transceiver mid.

### Android wrapper lifetime invariant (critical)

The Android WebRTC SDK disposes **every transceiver wrapper returned by the previous
`PeerConnection.getTransceivers()` call** each time the method is invoked. Disposal cascades:
`RtpTransceiver.dispose()` → receiver wrapper → cached `VideoTrack` wrapper, and
`VideoTrack.dispose()` removes every renderer sink attached through that wrapper via
`nativeRemoveSink`. An ad-hoc `getTransceivers()` probe for one participant therefore silently
detaches the live EGL sinks of every other participant — the historical cause of alternating
remote-tile freezes in 3-party calls.

Consequently, on Android:

- `AndroidWebRTCTrackResolver` (Kotlin) is the **single owner** of `getTransceivers()`. It keeps
  a per-PeerConnection snapshot (`WeakHashMap`) and all camera/screen/audio track and transceiver
  lookups read from that snapshot, returning stable platform wrappers between rotations.
- The snapshot is invalidated only at genuine receiver-rotation boundaries: set-local /
  set-remote description success, `addTransceiver` / `addTrack` mutations, and peer-connection
  teardown. The next resolution after invalidation refreshes exactly once; the post-renegotiation
  attach episode then re-attaches every tile with the new wrappers.
- No other code may call `getTransceivers()`, `getReceivers()`, or `getSenders()` per-probe.
- Hangup must **retire** the Java `PeerConnection` before `close()`/`dispose()`.
  `peerConnectionIsUsableForTransceiverLookup` reads only that retired set. Querying
  `signalingState()` after native teardown SIGSEGVs (`nativeSignalingState`, fault `0xd4`).
  In-flight ``renderRemoteVideoForParticipant`` after local-media release must abort.

## Apple architecture

### Tile lifecycle

1. Roster / track events arrive via ``RTCGroupCall/events()`` or internal
   ``RemoteParticipantTrackEvent`` streams.
2. ``VideoCallViewController`` creates one ``NTMTKView`` / ``SampleBufferViewRenderer`` per remote
   participant when ``shouldUseParticipantCameraTiles()`` is true.
3. ``RTCSession/renderRemoteVideoForParticipant`` resolves the live mapped track, optionally
   refreshes the group binding, and calls `track.add(renderer)`.
4. After SFU renegotiation, session rebind clears stale attachment state and emits
   ``RemoteParticipantTrackEvent`` with `isActive: true` for affected participants.
5. The view controller re-calls ``renderRemoteVideoForParticipant`` (sometimes with
   `forceParticipantRendererRebind: true`).

### Recovery (event-driven)

Apple group tiles use **inbound video flow sampling** (``RTCSession`` stats deltas) plus renderer
callbacks—not polling attach loops:

- **Decode advancing, tile stalled:** ``recoverInboundRemoteVideoAfterDecodeStall`` or participant
  re-attach with `forceParticipantRendererRebind`.
- **Decoder stalled with current binding:** ``recoverInboundRemoteParticipantVideoDecoderAfterMatchedBindingStall``.
  When the inbound FrameCryptor is healthy, this is **PLI-first** (pulse track + re-send SFU
  `mediaReady` so the SFU emits a throttled keyframe PLI). Full cryptor/renderer rebind runs only
  when the cryptor is missing, disabled, or reporting failure. Poll and decodeStalled transition
  share a 15s single-flight cooldown.
- **Overlay / expectation updates:** driven by flow state and tile overlay policy.

``AndroidGroupParticipantRendererRecoveryPolicy`` in `AndroidMultipartyVideoLayout.swift` mirrors
these rules for Android; the policy is shared conceptually even though types are platform-scoped.

### What Apple does *not* need

Apple does **not** use ``PostSfuRenegotiationAttachEpisode``. Settlement is:

```
session map rebind → RemoteParticipantTrackEvent → per-tile renderRemoteVideoForParticipant
```

That is sufficient because Metal renderer lifetime is simpler than Android EGL surface reinit, and
there is no multi-tile EGL generation coupling.

## Android architecture

Android multiparty video adds a **coordinated settlement layer** because:

- ``SurfaceViewRenderer`` requires EGL context reinit when surface/generation changes.
- Rebinding one tile can transiently affect sink generation state on siblings.
- Compose layout can deliver surfaces after tracks are already mapped.

Device rotation with `configChanges` is **not** a grid-slot or SFU attach event. Holder and
`OnLayout` callbacks must not reinit EGL on dual-axis intermediate sizes — that starves the
shared local-preview context and skips TextureView frames. Layout must also keep the
`SurfaceView` match-parent until the window matches configuration and the Compose tile
has settled: wrap-content `onMeasure` (317↔1002, then 155/488/2394 during rotate) is the
main-thread hitch even when EGL is left alone. 1-up leftover fullscreen and rotation
fragments stay match-parent; a settled 16:9 conference tile letterboxes in that apply
(do not wait for a second 1002 fill → 317 hop). 1-up ↔ conference flips `fillMaxSize` ↔
16:9 `aspectRatio`; letterbox uses one exact fitted size after that tile lands, not
`WRAP_CONTENT` on every `onFrameResolutionChanged`.

Visible Android tiles follow **live camera presence** (session map or conference
`videoEnabled`), not the channel roster. A participant-left / pruned-map event must
release the assignment immediately so 2-up returns to 1:1 — `videoEnabled` and the
channel roster must not keep the departed tile, and a skip-already-settled episode
must **clear** so the coordinator does not run for minutes. An explicit leave
(`explicitlyDeparted`) wins over a leftover mapped camera — Device3 08:21
re-assigned `mm26` from the session map after `Releasing departed` and stayed in
the 16:9 grid with one live remote. Device3 16:17 then returned to 1:1 and
flipped back to 16:9 because inbound recovery and a post-leave `track added`
cleared departed while leftover SDP rematerialized `nudge`. Remember departed
when conference camera is already off, skip recovery/attach for that id, and
do not rematerialize a pruned Android camera mapping until conference camera
is on again. Clear departed only on a later live-camera rejoin that is not
still pruned: conference `video=true` and the prune set was cleared.
Android post-SFU settlement emits a ``PostSfuRenegotiationAttachEpisode``
and does **not** deliver controller `track added`, so the episode refresh
must apply that same gate. An in-flight leave-offer episode must not ignore
a grown rejoin refresh (`Ignoring coordinator request`) or
`stabilizeEpisodeForClear` against the finalize-start snapshot while the
new id is mapped and unassigned (Device3 07:53:14–22). An in-flight episode
must not `formUnion` a departed id back onto the grid, and remount / grid-layout
must not queue coordinator reruns while a pass is in flight. Leave 2-up → 1:1
must reattach the remaining sink immediately — do not wait for Compose
`layoutGeneration` and do not defer that leftover into an in-flight leave-offer
episode (Device3 17:23 remounted at 317×564, then the coordinator skipped).
Overlapping `tilesDidChange` refreshes must drop stale generations so only the
latest publish remounts. Do **not** remount the leftover `AndroidView` when
`itemCount` crosses 1 (`composeTileKey` is stable per renderer) — Device3
22:18:41 first-measured the remount at 317×564 and stayed there. Do **not**
remount the `AndroidRemoteGrid` `ComposeView` on 1↔N (`composeGridIdentity` is
stable). `applySolo` / `applyConference` + `fillMaxSize` ↔ 16:9 own the hop.
A conference lock on a still-fullscreen leftover must MATCH_PARENT the
SurfaceView — keeping the 1:1 exact letterbox (1080×607) overflowed the 16:9
cell and left the second remote at 0×0 (Device3 22:16:47–22:18:25). Do not
re-call attach while that surface is still queued. A solo lock on a still-16:9
leftover must MATCH_PARENT — letterboxing against that cell (317×564) is not
1:1 (Device3 22:45:36–22:47:51). 1-up Compose must not keep the leftover in a
Column/Row `aspectRatio` cell. Do not `egl_reinit_with_track` while the
surface is 0×0. A leftover remote that
still renders at conference-tile size is not 1:1. Join 1:1 → 2-up must
letterbox the first remote inside the settled 16:9 cell (`applyConferenceGridLayout`)
— do not guess a fullscreen viewport from the Compose tile’s `rootView`
(1002×564 looks “fullscreen” against itself) or `SCALE_ASPECT_FILL` the leftover
1:1 host (Device3 10:55 / 14:39: leftover BLAST-rejected at 1002×564).
`SCALE_ASPECT_FIT` on a MATCH_PARENT SurfaceView still FILLs the tile; the
leftover child must be the exact letterbox (317×564) in that apply. A 16:9
`aspectRatio` cell is never the activity window and never a rotation fragment.
`applyConferenceGridLayout` often runs while the leftover host is still
1080×2520 — the 16:9 cell size is the viewport
(`applyConferenceLetterboxForComposeTile`). Do not call
`remoteCameraHostContainer` after that letterbox: stale leftover 1:1
`container.width` MATCH_PARENT-FILLs 1002×564 (Device3 16:46:48 → BLAST
16:49:07). Keep an existing 317×564 conference letterbox when a later
apply still reads 1080×2520. A 9:16 camera buffer with rotation 90/270
must not swap to landscape and FILL that cell. Same-size OnLayout must
re-apply when the conference renderer is still MATCH_PARENT. Do not
letterbox from Compose `onSizeChanged` during `PerformTraversals`.
Leftover `Surface changed: 1080×2520 → 1002×564` is the conference cell —
`surface_holder_rotation_skip` must still exact-letterbox that MATCH_PARENT
surface (`maybeLetterboxConferenceSurface`), even if leftover is still
SOLO-locked from 1-up (Device3 19:19:56 rejoin stayed `1002` FILL after the
first hop letterboxed). 1-up fullscreen is never 16:9 (`1080×2520`).
`applySolo` itself must still MATCH_PARENT against a leftover 16:9 *host*
(do not compute 317 from `applySolo`). Do not leave the first remote
FILL at 1002×564 until the second tile’s first frame. Compose `update`
must letterbox from the SurfaceView size when the host still reads leftover
1:1. Do not skip a last-applied 317×564 apply while the renderer is
MATCH_PARENT again after remount. A 16:9 leftover surface letterboxes
even when layoutParams are wrap-content (parent EXACT-measured the cell).
`applyConference` on leftover 1:1 host must use the last settled 16:9 cell
from the previous 2-up **only when that cell matches the current window
orientation**. A portrait leftover cell (1002×564 → 317×564) must not be
kept or remembered after the window is landscape (Device3 23:05:32: 317
wrap while chrome was already 2394×231; return overflow `362×644` at
`y=-40`). MATCH_PARENT until the current-orientation 16:9 cell lands, then
one exact wrap. If apply still FILLs that cell, force the exact wrap.
Window size is the activity decor / display, not the 16:9 cell. A shared live sink must not
`requestPendingLiveWrapperRebind`; that queues an EGL tear after the next
frame stall. A dead Java wrapper must force-apply the live receiver on the
leave offer, not wait for tail frames.

1-up ↔ N-up wrap-content letterbox is also not a new surface: tearing the sink there
freezes remotes (`surface_holder_resize_reinit` 1080×2520 → 317×564 → 1002×564).
`surface_holder_rotation_skip` must accept the holder size so `egl_init_stale`
cannot force `egl_reinit_with_track` on the same hop. Attach / sink-reconcile use
``AndroidRendererLayoutPolicy/shouldAllowAttachDrivenEglReinit`` — one reinit only
after Compose layout has settled. The local PiP overlay size follows orientation
class, not every `GeometryReader` blip. Do not `.id()` ``AndroidVideoCallView`` to
chase rotation remounts — that recreates the renderer pool. Full-screen Android
call chrome must not apply `GeometryReader` pixel size as `.frame`; that remounts
the call on rotate (`onDisappear` + channel rejoin + bouncing controls).

Hangup dismisses the call view after chrome already sets `showsLocalPreview=false`
(`showCallView=false` / `Waiting`) while ``CallStateMachine`` can still be `Connected`.
`onDisappear` must release the local TextureView then — skipping as a “transient remount”
leaves `EglRenderer: LocalPreviewDuration` running after camera stop. Rotation remounts
keep `showsLocalPreview=true` and must not release.

In-app minimize is a **remote-only** floating tile. Keep ``AndroidLocalVideoView``
mounted and hide its surface (`INVISIBLE`); do not remount the call and do not
fill local into the boxed window. Attach native drag/tap on the remote host from
Compose `update` after the tile is boxed — the fullscreen factory never registers
`key=pip`. A still-fullscreen seed must defer until layout, not refuse forever.
Tap the floating remote tile to shrink/grow it; the return chip restores
full-screen chrome. During the full-screen call, tap the local overlay to
shrink/grow it (Apple `tapPreviewView` / `isMinimized`). That tap does not hide
local — in-app minimize is what hides local, and it does **not** hide remote.

Local preview pixels are **not** a `VideoTrack` sink. The send track shares a `VideoSource`
with the encoder; WebRTC's adapter (CPU overuse / `maxFramerate` sink wants) drops frames
for every sink on that source. Device3 showed `CameraStatistics: 15` fps while
`EglRenderer: LocalPreview` received 7 fps and dropped 0. The capturer observer fans frames
to the TextureView **before** `VideoSource`, so the PiP stays at camera rate.
Apple's PiP is `AVCaptureVideoPreviewLayer` (hardware). A second Camera2 output
on the Android TextureView is **not** that equivalent: Device3 09:49 attached
`1280x720`, then the PiP was rotated 90°, undersized, and still skippy while
camera fps floated 13–26. Upright I420 fanout → TextureView `EglRenderer` is
also not that path: Device3 13:16 rendered `120/0/120` at 30.0 and still
skipped while GC freed ~70MB every ~3s. Android local preview fans the camera
`TextureBuffer` to `EglRenderer` on the **shared** factory `EglBase` (required
to draw the OES texture). Do not `toI420` for the PiP — lesson 26 was
TextureBuffer **plus** readback on the same context, not TextureBuffer alone.
VideoSource and local preview both keep the camera `TextureBuffer`. Do not
`toI420` the send path or the PiP when Settings softening is on — Device3
13:03 dumped ~3M objects / 80MB every ~7s and skipped 30–46 frames (lesson 46).
“Soften video appearance” is a viewport-resolution mix in `RoundedRectGlDrawer`
(`uSoften`), not a full-res I420 worker. Capture fps is owned in Kotlin
(`AndroidRTCViewSupport.startLocalCameraCapture` at 30). WebRTC still prefers
`[15.0:30.0]`; first frame rewrites AE to `[30:30]` only — it must not recreate
the session onto the TextureView. Local overlay is a SurfaceView media overlay
(`setZOrderMediaOverlay`) so it does not composite a TextureView on top of
the remote hole-punch — Device3 16:20 still skipped at TextureBuffer 30/0/30
on TextureView. Round that overlay in the public EGL drawer (`RoundedRectGlDrawer`)
with a translucent `SurfaceView` so corner alpha composites over the remote.
`clipToOutline` and Compose `.clip` do not clip the hole-punch. Do not call
`SurfaceView` / `SurfaceControl.Transaction` corner APIs — they are not in the
public compileSdk 36 stubs (lesson 17). N-up remote grid tiles still match
Apple `RemoteViewItem` chrome (12 dp continuous corner, 1 dp white 12%
stroke) with a Compose `.border` **outside** a 1 dp `AndroidView` inset so
the hole-punch does not erase the stroke. Do not make remotes translucent
or `setZOrderMediaOverlay` to fake rounded video — transparent GL corners
would show chat through the hole. 1-up stays full-bleed. Send encodings
still follow ``RTCVideoQualityProfile``.

### Components

| Component | Responsibility |
|-----------|----------------|
| ``RTCSession`` | Connection map, Android receiver resolution, FrameCryptor, `rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded`, emits ``PostSfuRenegotiationAttachEpisode`` |
| ``AndroidVideoCallController`` | View↔participant assignment, **post-renegotiation attach coordinator**, inbound-flow recovery |
| ``AndroidSampleCaptureView`` (Kotlin) | EGL lifecycle, sink attach/detach, first-frame tracking, pending live-wrapper rebind |
| ``AndroidMultipartyVideoLayout.swift`` | Pure policy: ``GroupSfuVideoAttachPolicy``, ``AndroidGroupPostRenegotiationAttachCoordinator``, ``AndroidGroupParticipantRendererAttachPolicy``, recovery policy |

Host apps install views through ``AndroidVideoCallController/setVideoViews(local:remotes:)`` and
should not attach tracks directly except via ``RTCSession/renderRemoteVideoForParticipant``.

### Post-SFU renegotiation attach episode

When settlement completes, ``RTCSession`` emits one
``PostSfuRenegotiationAttachEpisode`` per rebound batch:

```swift
public struct PostSfuRenegotiationAttachEpisode: Sendable {
    public let connectionId: String
    public let participantIds: [String]
}
```

Subscribe via ``RTCSession/postSfuRenegotiationAttachEpisodeStream()``. ``AndroidVideoCallController``
is the intended consumer.

An **episode**:

1. Records affected participant ids for the connection.
2. Ensures each id has an assigned ``AndroidSampleCaptureView``.
3. Runs the **post-renegotiation attach coordinator** to completion.
4. Clears episode state so normal track events resume.

### Post-renegotiation attach coordinator

Single owner for tile binds while an episode is active. One coordinator pass:

```
Pass begin
  → session.rebindAndroidGroupRemoteParticipantVideoAfterSfuRenegotiationIfNeeded (pass 1 only)
Phase 1 — full attach for participants not yet settled this episode
  → performParticipantVideoAttach(reason: post-renegotiation-coordinator | grid-layout)
Phase 2 — wrapper sync for already-settled participants
  → reconcileSettledParticipantWrapperSyncIfNeeded
     (coordinator-settled-wrapper-sync attach or sink rebind)
First-frame reconcile pass
  → pre-first-frame EGL reconcile where needed
Pass-end stale sweep (when appropriate)
  → rebindStaleWrapperSinksForSettledParticipants
  → applyPendingLiveWrapperRebindsForParticipants (force at finalize when required)
Finalize
  → coordinator-settlement for any remaining unsettled ids
  → apply pending live-wrapper rebinds
  → promote tiles toward media-ready (rebind/attach when needed)
  → **await ``onFirstFrameRendered``** for bound tiles still warming up
  → clearPostRenegotiationAttachEpisode only when every surfaced tile is media-ready
  → if the participant set grows during finalize or stabilize, cancel first-frame waits and rerun the coordinator pass
  → do not clear after stabilize while `rerunNeeded` or a grown episode id is not media-ready
```

**Phase ordering matters:** new participants receive full attach before settled participants receive
wrapper sync, so a late joiner does not race ahead of an existing tile mid-rebind.

### Episode attach suppression

While an episode is active, **competing attach paths** are suppressed so only the coordinator
mutates sinks:

- ``participant-track-refresh`` from track events → UI update only; attach deferred to coordinator.
- Grid relayout → folded into coordinator (`post-renegotiation-grid-layout`).
- Ad-hoc attaches with unrelated reasons → suppressed; coordinator may rerun if needed.

Allowed coordinator reasons (never suppressed during an episode) include:

- `post-renegotiation-coordinator`
- `coordinator-settlement`
- `coordinator-settled-wrapper-sync`
- `post-renegotiation-first-frame-reconcile`
- `coordinator-finalize-media-ready`
- `coordinator-finalize-pending-wrapper`
- `late-participant-assignment`

See ``AndroidGroupPostRenegotiationAttachCoordinator/shouldSuppressParticipantVideoAttachReason(_:episodeActive:)``.

### Renderer probe model

Attach/skip decisions use ``ParticipantRendererAttachSnapshot`` built from atomic native probes:

| Probe field | Meaning |
|-------------|---------|
| `hasActiveSink` | Renderer has a sink matching current generation and surface |
| `boundTrackSharesRendererSinkWithTarget` | Attached platform track **is** the live map wrapper |
| `attachedTrackIsLive` | Attached object's WebRTC state is `LIVE` |
| `rendererLayoutNeedsSinkReconcile` | View size changed since last bind |

**Smooth rendering** (do not disturb):

```
attachedTrackIsLive && hadConfirmedFirstFrameSinceSinkAttach && hasActiveSink && sharesSinkWithLiveTarget && !framesStale
```

Historical `everConfirmedFirstFrame` on the negotiated track id is **not** sufficient after EGL
reinit or Java wrapper rotation resets the current sink generation.

**Needs wrapper sync** (common post-renegotiation):

```
!attachedTrackIsLive || !sharesSinkWithLiveTarget
```

During an active post-renegotiation episode, coordinator code **must not defer** wrapper sync merely
because the dead wrapper still shows recent frames—the session has already proven the attached
object is not live. Deferred pending rebinds are finalized with `forceApply` at pass-end/finalize
so tiles cannot stall waiting for a 6s stale threshold after the episode ends.

### Android EGL attach rules

``AndroidSampleCaptureView`` (Kotlin) owns:

- `rendererGeneration` / `sinkBoundGeneration` coupling
- EGL reinit when the surface is created or the Compose host tile actually changes size.
  Not on wrap-content / exact letterbox or dual-axis rotation intermediates.
  Letterbox waits for a settled tile, then uses one exact fitted size.
  Same-size `OnLayout` must not re-apply or reassign `layoutParams` — that
  requestLayouts forever and ANRs the call UI.
  Compose `AndroidView.update` reports a layout event only when the renderer
  size changes. A missing sink is an attach event, not a layout event.
  `OnLayoutChangeListener` must **post** reconcile (never `egl_reinit` inside
  `PerformTraversals`). Same-size OnLayout is a no-op. Coordinator attach
  posts one main-looper bind; it must not `runOnMainThreadSync` N tiles during
  an SFU episode. Unchanged assignment signatures must not republish
  `tilesDidChange` while the episode is in flight. Idle pool slots must not
  initialize EGL or EglRenderer stats until a track is assigned. Settings
  appearance softening is GL `uSoften` on the overlay and a latest-frame
  send TextureBuffer blit — never CPU `toI420` into `VideoSource`.
- Same-track-id wrapper rotation via remove stale sink → attach live track → optional EGL reinit
  when first frame was already confirmed
- ``requestPendingLiveWrapperRebind`` / ``applyPendingLiveWrapperRebindIfEligible`` for the narrow
  case **outside** an active coordinator episode where interrupting brief stale frames would flash

First-frame confirmation is event-driven via WebRTC ``RendererEvents/onFirstFrameRendered``.

### Inbound-flow recovery (Android)

``AndroidVideoCallController`` observes ``RTCSession`` inbound video flow snapshots. When inbound
decode advances but a tile stops rendering, ``AndroidGroupParticipantRendererRecoveryPolicy``
selects recovery:

- Apply pending live-wrapper rebind when attached track is dead.
- Sink rebind across settled participants when one tile's stall implies wrapper drift.
- ``inbound-render-recovery`` full attach when probes show no valid sink.

Recovery is gated on **counter deltas**, not wall-clock retry timers.

## E2EE integration points

Remote video E2EE is orthogonal to sink routing but must align with participant ids:

1. Receiver FrameCryptor is bound to `(participantId, trackId, receiverKey)`.
2. After renegotiation, ``reconcileAndroidReceiverFrameCryptorsAfterSfuRenegotiation`` /
   Apple equivalent rebinding runs when signaling settles.
3. ``RTCSession/handleAndroidVideoReceiverFrameCryptorReady`` may trigger map rebind + sink refresh
   once decrypt is ready—another event-driven attach trigger.

Frame keys still arrive via ``RTCSession/setFrameEncryptionKey(_:index:for:)`` from the host app
(<doc:GroupSfuFrameE2EE>).

## Host application contract

To be a **well-designed client** of PQSRTC group/conference video:

### Transport and session

- [ ] Implement ``RTCTransportEvents`` and route SFU offers/answers/candidates without generating
      extra client offers.
- [ ] Call ``RTCSession/createSFUIdentity`` / group join flow from <doc:Group-Calls>.
- [ ] Distribute per-sender frame keys and call ``setFrameEncryptionKey`` with stable sender ids.
- [ ] Send authoritative roster updates; do not emit empty rosters during transient reconnect.

### Apple UI

- [ ] Use ``VideoCallViewController`` patterns (or equivalent) with one renderer per participant.
- [ ] On ``RemoteParticipantTrackEvent`` / group events, call ``renderRemoteVideoForParticipant``.
- [ ] Do not cache ``RTCVideoTrack`` references across SFU renegotiation; always render through
      ``RTCSession`` so map rebind can swap wrappers.
- [ ] Start inbound flow sampling via session APIs when the call connects (view controller does this
      when polling overlays).

### Android UI

- [ ] Install ``AndroidVideoCallController`` with local + remote ``AndroidSampleCaptureView`` list.
- [ ] Let ``postSfuRenegotiationAttachEpisodeStream`` drive settlement (handled inside controller).
- [ ] Do **not** call ``renderRemoteVideoForParticipant`` for rebound participants while
      ``shouldDeferSfuGroupParticipantVideoAttach`` is true or a post-renegotiation episode is
      active—except through coordinator-owned reasons.
- [ ] Forward ``rendererDidUpdateLayout`` / ``rendererDidInitialize`` from Compose when surfaces
      change so EGL/generation state stays aligned.
- [ ] On hangup, detach native call-chrome overlays (the `android.R.id.content` hit
      layer and control exclusions). Leaving them after `showCallView` becomes false
      keeps HWUI drawing (`OpenGLRenderer` / `Choreographer`) on the chat window.
- [ ] On hangup, retire the Android `PeerConnection` before `close()`/`dispose()`.
      Do not call `signalingState()` to decide usability — that JNI SIGSEGVs after
      native teardown. In-flight ``renderRemoteVideoForParticipant`` must abort.
- [ ] Reach Kotlin call-chrome support from **compiled** Swift only through
      `AndroidCallChromeBridge` (transpiled). PQSRTC and the host app are Skip
      `mode: native`; an `#if SKIP` block inside a compiled function body is always
      false, so a direct `AndroidCallChromeNativeSupport.*` call there is silently dropped.
- [ ] Keep the host shell stable across rotation. Classify phone vs. tablet by the
      **smallest** container side; a width-based rule turns a landscape phone into a
      tablet, swaps the split-view tree, and remounts every call `SurfaceView`.

### Identifiers

- [ ] Use the same `participantId` for UI tiles, frame keys, and ``renderRemoteVideoForParticipant``.
- [ ] Configure ``RTCSession/setRemoteParticipantIdResolver`` if your SFU does not use
      `streamIds.first`.

## Testing and regression policy

Policy tables in `AndroidMultipartyVideoLayout.swift` and tests in
`GroupCallVideoRegressionTests.swift` encode the attach coordinator contract. When changing
settlement logic:

1. Update the **policy function** first (pure, testable).
2. Keep coordinator control flow thin—branch on policy results.
3. Add regression tests for new episode/suppression/wrapper-sync rules.
4. Verify logs show a single coordinator begin/end per episode, not rerun storms.

### Local debug trail (not in git)

While iterating on Android settlement, maintain a **local** working history at
`.cursor/debug/android-group-remote-video.md` (gitignored). Append every attempt—symptom,
hypothesis, files changed, pass/fail, log signatures, and *what not to repeat*. The DocC article
is the intended design; the debug file is the historical record of failed paths so the API can
be trimmed to what is actually needed.

The workspace rule `.cursor/rules/event-driven-rtc-fixes.mdc` requires reading and updating that
file before Android group video attach changes.

## Related APIs

- ``RTCSession/renderRemoteVideoForParticipant(to:connectionId:participantId:preferFreshPeerConnectionTrack:)``
- ``RTCSession/shouldDeferSfuGroupParticipantVideoAttach(for:)``
- ``RTCSession/postSfuRenegotiationAttachEpisodeStream()``
- ``PostSfuRenegotiationAttachEpisode``
- ``AndroidVideoCallController`` (Android host integration)
- ``RemoteParticipantTrackEvent`` (Apple tile refresh)

## See also

- <doc:Group-Calls> — join flow, roster, frame keys
- <doc:SFUSignalingOverview> — server-driven renegotiation, flags, defer rules
- <doc:GroupSfuFrameE2EE> — per-sender media keys
- <doc:SfuRemoteVideoFrameE2EE> — receiver FrameCryptor identity
- <doc:HostAppCallKitAndSFU> — iOS CallKit ordering with SFU bootstrap
