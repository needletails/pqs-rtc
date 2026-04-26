# Host app integration: CallKit and server SFU (iOS)

This article is the **canonical PQSRTC-side contract** for **inbound** 1:1 calls that use the **server WebRTC SFU** (ephemeral `#<uuid>` / SwiftSFU room). Host applications (e.g. Nudge) must preserve these **ordering and audio-session invariants** or you risk **one-way or no audio**, sometimes with video still working.

> Important: PQSRTC does not own CallKit. The **app** must defer certain steps until `provider(_:didActivate:)` and your WebRTC audio bind sequence have run. The SDK enforces what it can in ``RTCSession+State``; the rest is host responsibility.

## What goes wrong if ordering is broken

- **Symptom (callee, inbound, server SFU):** remote and/or local **audio** fails; **video** may still work; RTP may look “up” in logs while you hear nothing.
- **Causes:**
  1. **``AVAudioSession`` vs WebRTC (`AURemoteIO`)** — Starting or reconfiguring the audio graph before CallKit has activated the session (or double-applying mode) can yield `kAudioUnitErr_CannotDoInCurrentContext` / property errors; audio may never recover.
  2. **SFU media bootstrap too early** — Calling ``beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)`` (SFU `PeerConnection` + offer) at the end of `answer` **before** CallKit activation races the same engine and can break media.
  3. **PQSRTC `.connected` handler** — If the `AVAudioSession` is **already active** (normal CallKit path), PQSRTC **must not** call `setAudioMode` again “for safety.” The SDK only configures mode when the session is not yet active. Hosts must not reintroduce duplicate configuration elsewhere.

## Host requirements (do not regress)

### A. Inbound 1:1 server-SFU on iOS (CallKit)

1. Complete your signaling and ``answerCall`` / `groupCallNegotiation` as needed.
2. **Do not** call ``beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)`` for ephemeral 1:1 SFU until **after**:
   - `provider(_:didActivate:)` (or equivalent), and
   - WebRTC is bound to the live session: e.g. `setExternalAudioSession()` → `setAudioMode` → `activateAudioSession` (typical Nudge: `CallManager.handleAudioActivation`).
3. If `answer` runs while your app’s “audio is active” flag is false, **stash** the SFU room route and only run media bootstrap from the activation callback.
4. On a **new** answer transaction, clear any **stale** pending bootstrap so a previous room is not started.
5. When running deferred bootstrap, **verify** the call/room still matches the active call; drop if the user ended or the id changed.
6. For **1:1 ephemeral SFU**, **do not** start full media from the SFU `registration` message alone; wait until **`call_answered` semantics** and post-answer bootstrap (so the answering device and identity are known).
7. Classify “1:1 SFU media room” using an explicit SFU wire route (`channelWireId`, typically `#<uuid>`), not just a UUID `sharedCommunicationId`. Plain 1:1 P2P calls also use UUID communication ids; misclassifying them as SFU can route inbound offers into the wrong decrypt/handler path.

### B. PQSRTC SDK (this package)

- On `.connected`, if `audioSession.isActive`, PQSRTC **skips** redundant `setAudioMode` and only ensures WebRTC audio is enabled—see `RTCSession+State` implementation. Keep this behavior when merging.

### C. macOS and tests

- **macOS (no CallKit):** the same defer is usually **not** required; bootstrap after `answerCall` per your app.
- **Unit tests** may drive PQSRTC without CallKit; the “skip redundant mode” path covers active sessions there too.

## Regression signals (logs / Console)

- **Healthy:** logs indicating SFU media bootstrap is **deferred** until audio activation, then **started** after activation.
- **Unhealthy:** SFU `registration` immediately followed by full offer/media on inbound 1:1 before answer flow completes; `AURemoteIO` / `CannotDoInCurrentContext` / `ATAudioSessionPropertyManager` errors around answer time.

## Reference implementation

The Nudge app implements the defer/pending route pattern in `CallManager+Extension` / `CallManager` (iOS). Keep host code and this article in sync when changing call flow.

## See also

- <doc:SFUSignalingOverview>
- <doc:SfuRemoteVideoFrameE2EE> — if **remote video** fails with per-participant frame E2EE (separate from audio/CallKit issues above)
- `RTCSession+SDPHelpers.modifySDP` — if frame encryption is disabled and remote video still stalls/black-screens, verify H264 profile-level cap behavior
- ``RTCSession`` / ``beginGroupCallMediaAfterSfuRegistrationIfNeeded(sfuRecipientId:)``
