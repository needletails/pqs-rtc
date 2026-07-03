# Screen Share System Audio — TDD Implementation Plan

Production plan for **device / app audio during screen share** on Apple platforms (macOS first, then iOS). Written against the existing pqs-rtc architecture: webrtc-sdk Specs binary, ScreenCaptureKit / ReplayKit capture, fixed 3-mid SFU group-call contract.

---

## Goals

| Goal | Detail |
|------|--------|
| **User-visible** | “Share system audio” in the screen-share picker actually sends captured app audio to remote participants. |
| **No SDP contract break** | Mix app audio into the **existing mic track (mid=0)**. Do **not** add a fourth BUNDLE mid; `ScreenShareGroupCallContract` stays 3-mid. |
| **TDD-first** | Every layer ships with failing tests first; contract tests gate behavior before WebRTC integration. |
| **Clean boundaries** | Pure conversion → frame chunker → egress protocol → platform capture → session lifecycle. |
| **Production-safe** | Clean start/stop, no ghost audio after share ends, excludes own app audio, works with E2EE on the existing audio sender. |

## Non-goals (v1)

- Separate `screen_audio_*` track / fourth SDP mid (defer unless mix-into-mic proves insufficient).
- SFU server changes (audio still flows on mid=0).
- Android system-audio capture (follow-up phase; different MediaProjection API).
- Per-app audio taps (Core Audio taps) — only full display/window SCK audio + ReplayKit `audioApp`.

---

## Architecture decision: mix into mic (mid=0)

LiveKit and most browsers ultimately deliver screen audio on the **participant’s audio track**, not as a second negotiated m-line. NeedleTails already fixes group-call mids:

```
mid=0  audio  (mic)
mid=1  camera
mid=2  screen (video only)
```

**Inject captured system PCM into the outbound audio pipeline** while screen share is active. Remotes hear mic + shared app audio on the same track they already subscribe to. FrameCryptor binding on the existing audio sender is unchanged.

**Constraint (document in UI):** the local mic track must be **published** (not permanently muted at the transport layer) for remotes to receive mixed audio. If the user mutes, define product behavior: v1 = system audio is also not sent (simplest).

---

## Layer diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ RTCSession+ScreenShare (lifecycle: attach / detach egress)      │
└────────────────────────────┬────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────┐
│ WebRTCScreenShareSystemAudioEgress (webrtc-sdk ADM / push path) │
└────────────────────────────┬────────────────────────────────────┘
                             │ ScreenShareSystemAudioEgress protocol
┌────────────────────────────▼────────────────────────────────────┐
│ ScreenSharePCMFrameChunker (48 kHz stereo, 10 ms frames)        │
└────────────────────────────┬────────────────────────────────────┘
                             │ ScreenSharePCMFrame
┌────────────────────────────▼────────────────────────────────────┐
│ ScreenSharePCMSampleConverter (CMSampleBuffer / relay Data)       │
└────────────────────────────┬────────────────────────────────────┘
                             │
        ┌────────────────────┴────────────────────┐
        │                                         │
 MacScreenCaptureSource                   iOSScreenCaptureSource
 (SCStream .audio)                         (ReplayKit audioApp packets)
```

---

## Phase 0 — SPI spike (0.5 day, not TDD)

Before writing production code, confirm the webrtc-sdk **M144** Apple API surface in `needletails/Specs`:

1. Inspect XCFramework headers for one of:
   - `RTCAudioDevice` + `deliverRecordedData` injection point
   - Manual-rendering / supplementary capture APIs (Specs CHANGES: “Get play-out buffer for manual audio mode”, “AVAudioEngine based AudioDeviceModule”)
   - Any `CaptureFrame` / custom audio source on ObjC `RTCAudioSource`
2. Prototype in a throwaway target: push 10 ms of silence while screen sharing; verify remote RTP counters advance on mid=0.
3. Record chosen API in `ScreenShareSystemAudioContract.IntegrationStrategy` (enum, single value for v1).

**Exit criterion:** one documented integration path with a minimal spike PR or spike branch notes linked from this doc.

---

## Phase 1 — Contract & types (TDD)

**New files**

| File | Role |
|------|------|
| `ScreenShareSystemAudioContract.swift` | Canonical rules (like `ScreenShareGroupCallContract`) |
| `ScreenSharePCMFrame.swift` | `Sendable` value type: interleaved Int16, sampleRate, channelCount, frames |
| `ScreenShareSystemAudioEgress.swift` | Protocol + no-op + recording test double |

**Contract rules (v1)**

```swift
public enum ScreenShareSystemAudioContract: Sendable {
    /// Target format for WebRTC ingress.
    static let targetSampleRate: Int = 48_000
    static let targetChannelCount: Int = 2
    /// WebRTC expects 10 ms frames.
    static let frameDurationMs: Int = 10
    static var samplesPerChannelPerFrame: Int { targetSampleRate * frameDurationMs / 1_000 }

    /// App audio is only mixed while screen capture is active AND shareSystemAudio == true.
    /// Stopping screen share MUST flush/stop egress within one frame period.
    /// excludesCurrentProcessAudio must remain true on macOS SCK config.
    /// ReplayKit relay must only send audioApp when shareSystemAudio is true (already true in BroadcastHandler).
}
```

**Tests:** `ScreenShareSystemAudioContractTests.swift`

| Test | Asserts |
|------|---------|
| `targetFormat_is48kHzStereo10ms` | Constants math |
| `contract_samplesPerFrame_matchesWebRTCExpectation` | 480 samples/channel |

**Tests:** `ScreenShareSystemAudioEgressTests.swift` (using recording double)

| Test | Asserts |
|------|---------|
| `noopEgress_discardsFrames` | No crash, no storage |
| `recordingEgress_accumulatesFrameCount` | Test double receives pushed frames |

---

## Phase 2 — Pure PCM conversion (TDD)

**New file:** `ScreenSharePCMSampleConverter.swift`

Pure functions, no WebRTC / ScreenCaptureKit imports beyond `CoreMedia` where needed.

| Function | Input | Output |
|----------|-------|--------|
| `pcmFrame(fromCMSampleBuffer:)` | `CMSampleBuffer` | `[ScreenSharePCMFrame]` or throw |
| `pcmFrame(fromReplayKitPayload:sampleRate:channelCount:)` | relay `Data` + metadata | `[ScreenSharePCMFrame]` |
| `interleavedInt16(from:)` | raw PCM bytes + format | normalized interleaved samples |

Handle: Float32 / Int16, mono → stereo upmix, arbitrary sample rate (pass-through to chunker).

**Tests:** `ScreenSharePCMSampleConverterTests.swift`

| Test | Asserts |
|------|---------|
| `convertsInt16MonoCMSampleBuffer` | Sample count, amplitude preserved |
| `convertsFloat32StereoCMSampleBuffer` | Interleaving order L,R,L,R |
| `convertsReplayKitPayloadMetadata` | Uses width=sampleRate height=channels from packet |
| `rejectsEmptyBuffer` | Throws typed error |
| `rejectsUnsupportedFormat` | Throws typed error |

Use **fixture blobs** in `Tests/PQSRTCCompiledSwiftTests/Support/ScreenSharePCMFixtures.swift` (generated once from known-good buffers; commit small binary fixtures).

---

## Phase 3 — Frame chunker & resampler (TDD)

**New file:** `ScreenSharePCMFrameChunker.swift`

Stateful, but testable: accepts variable-size input frames, outputs **exactly** `ScreenShareSystemAudioContract.samplesPerChannelPerFrame` per channel at 48 kHz stereo.

| Behavior | Detail |
|----------|--------|
| Resample | Linear or AVAudioConverter-backed (prefer `AVAudioConverter` in impl, wrap for tests) |
| Buffer | Carry remainder across `push()` calls |
| Flush | `flush()` emits partial final frame padded with silence OR drop (contract: pad with silence) |
| Idle | No output when no input |

**Tests:** `ScreenSharePCMFrameChunkerTests.swift`

| Test | Asserts |
|------|---------|
| `emits480SamplesPerChannel_for10msAt48kHz` | Exact frame size |
| `carriesRemainderAcrossCalls` | 15 ms in → 1 full + 5 ms buffered |
| `resamples44kHzTo48kHz` | Output rate correct (use sine fixture, check period) |
| `monoUpmixesToStereo` | Duplicate channel |
| `flush_padsPartialFrameWithSilence` | Deterministic padding |
| `stop_afterFlush_emitsNoMoreFrames` | Clean teardown |

---

## Phase 4 — Egress protocol wiring (TDD)

**Update:** `ScreenShareSystemAudioEgress.swift`

```swift
protocol ScreenShareSystemAudioEgress: Sendable {
    func start() throws
    func push(_ frame: ScreenSharePCMFrame) throws
    func stop()
}
```

**New file:** `WebRTCScreenShareSystemAudioEgress.swift` (`#if canImport(WebRTC) && !os(Android)`)

Implements protocol using Phase 0 chosen webrtc-sdk API. Keeps all WebRTC imports out of converter/chunker.

**Tests:** `WebRTCScreenShareSystemAudioEgressTests.swift`

| Test | Asserts |
|------|---------|
| `start_isIdempotent` | Second start no-op or safe error |
| `stop_clearsPendingFrames` | After stop, push is ignored |
| `push_beforeStart_throws` | Fail fast |

Integration tests (compiled Swift, optional CI gate):

| Test | Asserts |
|------|---------|
| `integration_pushSilence_advancesOutboundAudioPackets` | Requires loopback or mock PC; gate behind `#if PQSRTC_WEBRTC_INTEGRATION_TESTS` |

---

## Phase 5 — Capture source integration (TDD)

### macOS — `MacScreenCaptureSource.swift`

Replace `handleAudioSampleBuffer` drop with:

```swift
converter → chunker → egress.push
```

- Inject `ScreenShareSystemAudioEgress?` at init (default `NoOp` for tests).
- Only wire audio output when `options.shareSystemAudio && RTCSession.supportsScreenShareSystemAudioEgress`.
- Call `egress.stop()` + `chunker.reset()` in `stopCapture()`.

**Tests:** `MacScreenCaptureSourceAudioTests.swift`

Use a **fake egress**; no real SCK in unit tests.

| Test | Asserts |
|------|---------|
| `doesNotInvokeEgress_whenShareSystemAudioFalse` | |
| `invokesEgress_whenShareSystemAudioTrueAndSupported` | Fake receives frames after injecting synthetic CMSampleBuffer via package-visible test hook |
| `stopCapture_stopsEgress` | Fake `stop()` called |

Add `@testable` test hook: `MacScreenCaptureSource._test_handleAudioSampleBuffer(_:)` if needed to avoid SCK.

### iOS — `iOSScreenCaptureSource.swift`

In `handle(packet:)` for `.audioApp`:

```swift
converter.pcmFrame(fromReplayKitPayload:...) → chunker → egress.push
```

Ignore `.audioMic` for v1 (mic already on main audio track; avoids double mic).

**Tests:** extend `ReplayKitBroadcastRelayPacketTests` + new `iOSScreenCaptureSourceAudioTests.swift`

| Test | Asserts |
|------|---------|
| `audioAppPacket_routedToEgress_whenEnabled` | |
| `audioAppPacket_ignoredWhenShareSystemAudioFalse` | Matches relay options gating |
| `audioMicPacket_ignoredInV1` | Documented behavior |

---

## Phase 6 — Session lifecycle (TDD)

**Update:** `RTCSession+ScreenShare.swift`

| Change | Detail |
|--------|--------|
| Remove stale comment | webrtc-sdk fork supports push; update doc on `supportsScreenShareSystemAudioEgress` |
| Feature flag | `public static var supportsScreenShareSystemAudioEgress: Bool` — compile-time or runtime; v1: `true` on Apple after Phase 4 ships |
| `startScreenShare` | Create/start `WebRTCScreenShareSystemAudioEgress`, pass into capture source |
| `stopScreenShare` | Stop egress **before** removing screen video track (LiveKit ghost-audio lesson) |
| Storage | `_screenShareSystemAudioEgress` on session or connection |

**Tests:** `ScreenShareSystemAudioLifecycleTests.swift`

| Test | Asserts |
|------|---------|
| `startWithShareSystemAudio_attachesEgress` | Fake factory injects egress |
| `stopScreenShare_stopsEgressBeforeVideoTeardown` | Order enforced via recording double |
| `startWithShareSystemAudioFalse_doesNotAttachEgress` | |
| `supportsFlag_false_rejectsShareSystemAudioTrue` | Existing guard preserved until flag flipped |

**Update:** `CallConferenceTests.screenShareSystemAudioEgressIsExplicitWhenUnsupported` → rename when flag becomes true.

### Group-call / SDP regression

No contract changes expected. Run existing suites:

- `ScreenShareGroupCallSDPScenarioTests`
- `ScreenShareRenegotiationTests`
- `ScreenShareRenderingAndLifecycleTests`

Add one test:

| Test | Asserts |
|------|---------|
| `sharerStartShareOffer_mid0Unchanged_whenSystemAudioEnabled` | mid=0 still single audio m-line; directions unchanged vs fixture |

---

## Phase 7 — UI & product (TDD where possible)

**Update:** `ScreenSharePickerView.swift`

- Enable toggle when `supportsScreenShareSystemAudioEgress`.
- Helper text: “Includes audio from the shared display or window. Your microphone must be on for others to hear it.”
- Localizable strings in `Localizable.xcstrings`.

**Tests:** `ScreenSharePickerViewTests.swift` (if SwiftUI testing exists) or snapshot-less unit test on binding logic extracted to `ScreenShareOptionsValidator`.

---

## Phase 8 — Observability & soak

**Stats:** extend `RTCSession+Stats` screen-share diagnostics:

```
screenSystemAudioFramesPushed=…
screenSystemAudioLastPushMsAgo=…
```

**Manual soak checklist**

- [ ] macOS: share display with YouTube audio → remote hears it
- [ ] macOS: stop share → remote hears silence within 200 ms
- [ ] macOS: share with mic muted → remote hears nothing (v1 behavior)
- [ ] iOS: ReplayKit broadcast + system audio → remote hears it
- [ ] Group call 3+ participants, E2EE on
- [ ] Preempt screen share (exclusive room) → no ghost audio from prior sharer
- [ ] 1:1 SFU call path

---

## Phase 9 — Android (follow-up)

Android already uses `io.github.webrtc-sdk:android`. Investigate `AudioPlaybackCaptureConfiguration` + screen capture service. Same converter/chunker/egress protocol; platform-specific capture only. Separate plan section when macOS + iOS are stable.

---

## File checklist (ordered delivery)

| Order | File | Phase |
|-------|------|-------|
| 1 | `ScreenShareSystemAudioContract.swift` | 1 |
| 2 | `ScreenSharePCMFrame.swift` | 1 |
| 3 | `ScreenShareSystemAudioEgress.swift` | 1 |
| 4 | `Tests/.../ScreenShareSystemAudioContractTests.swift` | 1 |
| 5 | `ScreenSharePCMSampleConverter.swift` | 2 |
| 6 | `Tests/.../ScreenSharePCMSampleConverterTests.swift` | 2 |
| 7 | `Tests/.../Support/ScreenSharePCMFixtures.swift` | 2 |
| 8 | `ScreenSharePCMFrameChunker.swift` | 3 |
| 9 | `Tests/.../ScreenSharePCMFrameChunkerTests.swift` | 3 |
| 10 | `WebRTCScreenShareSystemAudioEgress.swift` | 4 |
| 11 | `Tests/.../WebRTCScreenShareSystemAudioEgressTests.swift` | 4 |
| 12 | `MacScreenCaptureSource.swift` (audio path) | 5 |
| 13 | `iOSScreenCaptureSource.swift` (audio path) | 5 |
| 14 | `RTCSession+ScreenShare.swift` (lifecycle) | 6 |
| 15 | `ScreenSharePickerView.swift` | 7 |

---

## TDD workflow per PR

Each PR should:

1. Add failing tests (Swift Testing `@Test`).
2. Implement minimal code to pass.
3. Run `PQSRTCCompiledSwiftTests` on macOS.
4. No production code without a test except Phase 0 spike (documented separately).

Suggested PR sequence:

| PR | Scope |
|----|-------|
| **PR1** | Phase 0 spike notes + Phase 1 contract/types + test doubles |
| **PR2** | Phase 2 converter + fixtures |
| **PR3** | Phase 3 chunker |
| **PR4** | Phase 4 WebRTC egress |
| **PR5** | Phase 5 macOS capture wiring |
| **PR6** | Phase 6 session lifecycle + flip flag + SDP regression |
| **PR7** | Phase 5 iOS ReplayKit wiring |
| **PR8** | Phase 7 UI + Phase 8 stats |

---

## Risks & mitigations

| Risk | Mitigation |
|------|------------|
| webrtc-sdk ObjC lacks public push API on Apple | Phase 0 spike; fallback to custom `RTCAudioDevice` ADM wrapper |
| Ghost audio after stop | Stop egress before video teardown; chunker flush; test order in lifecycle tests |
| Sample-rate drift / chipmunk | Chunker resamples all input to 48 kHz; sine fixture tests |
| Mic muted but user expects app audio | v1: document; v2: allow app-only via manual rendering mode |
| E2EE key on wrong sender | Mix into existing audio sender only; no new track id |
| CPU cost | Chunker runs on existing `audioSampleQueue`; profile on M-series + Intel |

---

## Success criteria

- [ ] All new tests green in `PQSRTCCompiledSwiftTests`
- [ ] Existing screen-share contract tests green (no mid topology change)
- [ ] `supportsScreenShareSystemAudioEgress == true` on Apple
- [ ] Picker toggle enabled; error path removed for macOS
- [ ] Manual soak checklist passed on macOS + iOS
- [ ] No `Captured ScreenCaptureKit system-audio samples, but this WebRTC build does not expose...` warnings in logs during normal operation

---

## References in repo

| Area | Location |
|------|----------|
| Current gate | `RTCSession+ScreenShare.swift` — `supportsScreenShareSystemAudioEgress` |
| macOS capture (audio dropped) | `MacScreenCaptureSource.handleAudioSampleBuffer` |
| iOS relay (audio dropped) | `iOSScreenCaptureSource.handle(packet:)` `.audioApp` |
| ReplayKit extension | `Apps/nudge-app/Darwin/RPBroadcastExtension/BroadcastHandler.swift` |
| Group-call mids | `ScreenShareGroupCallContract.MediaMid` |
| Contract test pattern | `ScreenShareGroupCallSDPScenarioTests.swift` |
| WebRTC binary | `needletails/Specs` → `webrtc-sdk/Specs` M144.7559.04 |
