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

- Individual ``RemoteParticipantTrackEvent`` notifications may be suppressed or queued.
- Android queues rebound ids until settlement; Apple queues sink refresh ids in
  `pendingParticipantRendererSinkRefreshByConnectionId`.

> Important: Defer ends when renegotiation completes **and** signaling is stable—not on a timer.

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
selects the participant id list for the post-settlement episode—rebound participants only, not
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
  → rendererDidUpdateLayout on all assigned views
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
  → if the participant set grows during finalize, cancel first-frame waits and rerun the coordinator pass
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
- EGL reinit when surface becomes ready or layout requires resync
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
